// Probe for AutoMix: how does Deezer change songs, and does Apple have the
// analysis a beat-matched mix would plan from?
//
// Deezer 11.27.0's player is DZRAudioPlayer (ObjC). Its own crossfade goes
// through it (types from the binary's method lists):
//   - (double)crossFadeDurationForPlayable:followedByPlayable:   per pair of tracks
//   - (void)mixablePlaybackWillStartPlaybackRelease:withDuration:  A's fade-out starts
//   - (void)mixablePlaybackDidFinishPlaybackAttack:               B's fade-in is done
//   - (void)notifyPlayerDidChangeTrack, trackPlayback... callbacks, the progress
// and DeezerTrack has -isrc. This logs, with times in seconds since launch:
//   1. those events, with the tracks (title / artist / ISRC / duration / gain)
//      and Deezer's crossfade length;
//   2. around each change (from 25 s before the current track's end to 10 s
//      after the change), every player node's level per ~0.5 s of audio and
//      when that audio will be heard (from the buffer probe's queue), so the
//      overlap and the fades show;
//   3. for each track, Apple Music's catalog song with that ISRC and a summary
//      of its audio analysis (the fields Apple's AutoMix uses: beats, bars,
//      key, loudness, fades, ...), once per ISRC.
// Read-only: nothing Deezer does is changed. Lines start with "automix:".

#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAppleMusic.h"
#import "DZAutoMixProbe.h"

@interface DZRAudioPlayer : NSObject
- (double)crossFadeDuration;
- (double)playbackDuration;
- (double)playbackElapsedTime;
- (id)currentTrack;
@end

static _Atomic double sWindowUntil;      // CACurrentMediaTime() until which levels are logged
static BOOL sWindowOpen;                  // opened for the current track's end
static NSMutableDictionary<NSString *, NSNumber *> *sLastEvent;   // rate limit for chatty events

static double clock_s(void) { return CACurrentMediaTime(); }

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *trackDesc(id t) {
    if (!t) return @"nil";
    return [NSString stringWithFormat:@"%@ \"%@\" / %@ · isrc %@ · %@ s · gain %@", NSStringFromClass([t class]),
            kv(t, @"title") ?: @"?", kv(t, @"artistName") ?: @"?", kv(t, @"isrc") ?: @"-",
            kv(t, @"duration") ?: @"?", kv(t, @"gain") ?: @"-"];
}

// A track controller / mixable: its class, and its track when it says.
static NSString *controllerDesc(id c) {
    if (!c) return @"nil";
    id track = kv(c, @"track") ?: kv(c, @"playable") ?: kv(c, @"currentTrack");
    return [NSString stringWithFormat:@"%@ %p%@", NSStringFromClass([c class]), c,
            track ? [NSString stringWithFormat:@" (%@)", kv(track, @"title") ?: NSStringFromClass([track class])] : @""];
}

static NSString *position(DZRAudioPlayer *p) {
    @try {
        return [NSString stringWithFormat:@"at %.1f / %.1f s", [p playbackElapsedTime], [p playbackDuration]];
    } @catch (NSException *e) {
        return @"";
    }
}

// Chatty events (called often) are logged at most once a second each.
static BOOL due(NSString *event) {
    double now = clock_s();
    @synchronized ([DZRAudioPlayer class]) {
        if (!sLastEvent) sLastEvent = [NSMutableDictionary dictionary];
        if (now - sLastEvent[event].doubleValue < 1.0) return NO;
        sLastEvent[event] = @(now);
    }
    return YES;
}

static void openWindow(double seconds, NSString *why) {
    double until = clock_s() + seconds;
    if (until > atomic_load(&sWindowUntil)) atomic_store(&sWindowUntil, until);
    DZLog("automix: levels logged for %.0f s (%@)", seconds, why);
}

#pragma mark - Apple's analysis

static NSString *brief(id v, int depth);

static NSString *briefDict(NSDictionary *d, int depth) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [parts addObject:[NSString stringWithFormat:@"%@: %@", k, brief(d[k], depth + 1)]];
    }
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
}

// A short picture of a JSON value: numbers and short strings as they are,
// arrays as their length plus their first element, objects as their keys.
static NSString *brief(id v, int depth) {
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = v;
        return s.length > 40 ? [NSString stringWithFormat:@"\"%@…\"", [s substringToIndex:40]] : [NSString stringWithFormat:@"\"%@\"", s];
    }
    if ([v isKindOfClass:[NSNumber class]]) return [v description];
    if ([v isKindOfClass:[NSArray class]]) {
        NSArray *a = v;
        return a.count ? [NSString stringWithFormat:@"[%lu × %@]", (unsigned long)a.count, depth < 3 ? brief(a.firstObject, depth + 1) : @"…"]
                       : @"[]";
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = v;
        if (depth >= 3) return [NSString stringWithFormat:@"{%@}", [[d.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]];
        return briefDict(d, depth);
    }
    return v ? NSStringFromClass([v class]) : @"null";
}

// The resources a relationship points at, with their attributes (inline, or
// in the reply's top-level "included").
static NSArray<NSDictionary *> *related(NSDictionary *song, NSString *name, NSArray *included) {
    NSArray *items = song[@"relationships"][name][@"data"];
    if (![items isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *full = it;
        if (!it[@"attributes"]) {
            for (NSDictionary *inc in included) {
                if ([inc isKindOfClass:[NSDictionary class]] && [inc[@"id"] isEqual:it[@"id"]] && [inc[@"type"] isEqual:it[@"type"]]) { full = inc; break; }
            }
        }
        [out addObject:full];
    }
    return out;
}

static void lookUpAnalysis(NSString *isrc, NSString *label) {
    if (![isrc isKindOfClass:[NSString class]] || isrc.length < 10) {
        DZLog("automix: %@ has no ISRC, no Apple analysis", label);
        return;
    }
    static NSMutableSet<NSString *> *asked;
    @synchronized ([DZRAudioPlayer class]) {
        if (!asked) asked = [NSMutableSet set];
        if ([asked containsObject:isrc]) return;
        [asked addObject:isrc];
    }
    NSString *path = [NSString stringWithFormat:@"songs?filter%%5Bisrc%%5D=%@&include=audio-analysis,flexml-analysis"
                      @"&extend%%5Baudio-analysis%%5D=fades,loudnessCurve",
                      [isrc stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]];
    DZAppleCatalogGet(path, ^(NSData *data, NSInteger status) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *songs = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        if (![songs isKindOfClass:[NSArray class]] || !songs.count) {
            DZLog("automix: Apple has no song with ISRC %@ (HTTP %ld) · %@", isrc, (long)status, label);
            return;
        }
        NSArray *included = [json[@"included"] isKindOfClass:[NSArray class]] ? json[@"included"] : @[];
        NSDictionary *song = songs.firstObject;
        NSDictionary *a = song[@"attributes"];
        DZLog("automix: Apple song %@ for %@: \"%@\" / %@ · %.1f s · %lu match(es) · relationships %@",
              song[@"id"], isrc, a[@"name"] ?: @"?", a[@"artistName"] ?: @"?", [a[@"durationInMillis"] doubleValue] / 1000,
              (unsigned long)songs.count, [[song[@"relationships"] allKeys] componentsJoinedByString:@", "] ?: @"none");
        for (NSString *rel in @[@"audio-analysis", @"flexml-analysis"]) {
            NSArray *items = related(song, rel, included);
            if (!items.count) {
                DZLog("automix: %@ · %@: none", isrc, rel);
                continue;
            }
            for (NSDictionary *it in items) {
                NSString *text = brief(it[@"attributes"] ?: it, 0);
                // long enough to see the shape, short enough for the log
                if (text.length > 3000) text = [[text substringToIndex:3000] stringByAppendingString:@" …"];
                DZLog("automix: %@ · %@ %@: %@", isrc, rel, it[@"id"] ?: @"", text);
            }
        }
    });
}

#pragma mark - levels around a change

typedef struct { double sumSq; long frames; double heardAt; } DZLevelAcc;
static NSMutableDictionary<NSNumber *, NSValue *> *sAcc;

BOOL DZAutoMixProbeWants(void) {
    return clock_s() < atomic_load(&sWindowUntil);
}

void DZAutoMixProbeBuffer(NSUInteger serial, AVAudioPCMBuffer *buffer, double aheadBefore) {
    if (!DZAutoMixProbeWants() || buffer.format.commonFormat != AVAudioPCMFormatFloat32 || !buffer.floatChannelData) return;
    AVAudioFrameCount n = buffer.frameLength;
    AVAudioChannelCount chs = buffer.format.channelCount;
    double sum = 0;
    for (AVAudioChannelCount c = 0; c < chs; c++) {
        float ms = 0;
        vDSP_measqv(buffer.floatChannelData[c], buffer.stride, &ms, n);
        sum += (double)ms * n;
    }
    double sr = buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 44100;
    @synchronized ([DZRAudioPlayer class]) {
        if (!sAcc) sAcc = [NSMutableDictionary dictionary];
        DZLevelAcc acc = {0, 0, 0};
        NSValue *v = sAcc[@(serial)];
        if (v) [v getValue:&acc];
        if (acc.frames == 0) acc.heardAt = aheadBefore;
        acc.sumSq += sum / (chs ? chs : 1);
        acc.frames += n;
        if (acc.frames >= sr / 2) {
            double rms = sqrt(acc.sumSq / acc.frames);
            DZLog("automix: player #%lu level %.1f dB · heard in %.2f s (%.2f s of audio)", (unsigned long)serial,
                  rms > 1e-7 ? 20 * log10(rms) : -140.0, acc.heardAt, acc.frames / sr);
            acc = (DZLevelAcc){0, 0, 0};
        }
        sAcc[@(serial)] = [NSValue valueWithBytes:&acc objCType:@encode(DZLevelAcc)];
    }
}

#pragma mark - hooks

%group DZAutoMixProbeHooks

%hook DZRAudioPlayer

- (double)crossFadeDurationForPlayable:(id)a followedByPlayable:(id)b {
    double d = %orig;
    if (due([NSString stringWithFormat:@"pair %p %p", a, b])) {
        DZLog("automix: crossfade for the pair: %.2f s (setting %.2f s) · A %@ · B %@", d, [self crossFadeDuration], trackDesc(a), trackDesc(b));
        lookUpAnalysis(kv(a, @"isrc"), @"A");
        lookUpAnalysis(kv(b, @"isrc"), @"B");
    }
    return d;
}

- (void)setCrossFadeDuration:(double)d {
    %orig;
    DZLog("automix: setCrossFadeDuration: %.2f s", d);
}

- (void)applyCrossFadeDurationForNextTrackChange {
    %orig;
    if (due(@"apply")) DZLog("automix: applyCrossFadeDurationForNextTrackChange → %.2f s, %@", [self crossFadeDuration], position(self));
}

- (void)updateNextTrackTransition {
    %orig;
    if (due(@"update")) DZLog("automix: updateNextTrackTransition, %@", position(self));
}

- (void)prepareNextTrackControllerIfNeeded {
    %orig;
    if (due(@"prepare")) DZLog("automix: prepareNextTrackControllerIfNeeded, %@", position(self));
}

- (void)scheduleNextTrackControllerStart {
    DZLog("automix: scheduleNextTrackControllerStart, %@", position(self));
    %orig;
}

- (void)mixablePlaybackWillStartPlaybackRelease:(id)mixable withDuration:(double)d {
    DZLog("automix: A's release (fade-out) starts: %.2f s · %@ · %@", d, controllerDesc(mixable), position(self));
    openWindow(d + 12, @"release");
    %orig;
}

- (void)mixablePlaybackDidFinishPlaybackAttack:(id)mixable {
    DZLog("automix: B's attack (fade-in) finished · %@ · %@", controllerDesc(mixable), position(self));
    %orig;
}

- (BOOL)playNextTrackWithChange:(id)change {
    BOOL r = %orig;
    DZLog("automix: playNextTrackWithChange: %@ → %d", change ? [[change description] substringToIndex:MIN((NSUInteger)160, [[change description] length])] : @"nil", r);
    return r;
}

- (void)notifyPlayerDidChangeTrack {
    %orig;
    sWindowOpen = NO;
    DZLog("automix: track changed → %@ · %@", trackDesc([self currentTrack]), position(self));
    openWindow(10, @"after the change");
    lookUpAnalysis(kv([self currentTrack], @"isrc"), @"now playing");
}

- (void)trackPlaybackWillStartPlaying:(id)c {
    DZLog("automix: trackPlaybackWillStartPlaying %@", controllerDesc(c));
    %orig;
}

- (void)trackPlaybackDidStartPlaying:(id)c {
    %orig;
    DZLog("automix: trackPlaybackDidStartPlaying %@", controllerDesc(c));
}

- (void)trackPlaybackDidReachLastBuffer:(id)c {
    %orig;
    DZLog("automix: trackPlaybackDidReachLastBuffer %@ · %@", controllerDesc(c), position(self));
}

- (void)trackPlaybackDidFinishPlaying:(id)c {
    DZLog("automix: trackPlaybackDidFinishPlaying %@", controllerDesc(c));
    %orig;
}

- (void)trackPlaybackDidProgress:(id)c toElapsedTime:(double)t {
    %orig;
    double total = 0;
    @try { total = [self playbackDuration]; } @catch (NSException *e) {}
    if (!sWindowOpen && total > 30 && total - t < 25 && total - t > 0) {
        sWindowOpen = YES;
        DZLog("automix: %.1f s left of %@ (crossfade setting %.2f s)", total - t, trackDesc([self currentTrack]), [self crossFadeDuration]);
        openWindow(total - t + 12, @"end of the track");
    }
}

%end

%end

void DZAutoMixProbeInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!DZPrefBool(kDZAudioHook)) return;
        Class player = objc_getClass("DZRAudioPlayer");
        SEL need = @selector(crossFadeDurationForPlayable:followedByPlayable:);
        if (!player || !class_getInstanceMethod(player, need)) {
            DZLog("automix: DZRAudioPlayer not as expected, probe off");
            return;
        }
        %init(DZAutoMixProbeHooks);
        DZLog("automix: probe on (Deezer's song changes, levels around them, Apple's analysis per ISRC)");
    });
}
