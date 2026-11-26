// AutoMix: Deezer's crossfade, planned for each pair of songs.
//
// What the AutoMix probe showed on Deezer 11.27.0 (iOS 27.3):
//   - DZRAudioPlayer asks -crossFadeDurationForPlayable:followedByPlayable:
//     for the pair (current, next) when a song starts, when the queue changes
//     and when the setting changes. With a crossfade of D seconds it starts
//     the next song from 0:00 on a second player node and fades the current
//     one out over D, starting at its length minus D. Skips are hard cuts.
//   - Each song is decoded by a DZRAudioTrackController (Deezer cycles
//     through three) via -readAudioIntoBuffer:frames:endReached:, about 3 s
//     before it's heard; its -track is a DZRDownloadableObject whose
//     -playableObject is the DeezerTrack (-isrc, -title).
//
// AutoMix answers that question itself: B's first downbeat lands on A's bar
// line where A's music winds down (DZPlanCrossfade). The knowledge comes from
//   1. Apple Music's audio analysis, looked up by ISRC (bars, fade-out), and
//   2. Deezit's own: a song that plays from its start to its end without a
//      seek is analysed as it's decoded (DZSongAnalyzer) and remembered.
// Where the music ends comes from Deezit's own analysis when there is one (it
// measured Deezer's file), bars from Apple when it has them. A pair with
// nothing known about A keeps Deezer's own value. Lines start with "automix:".

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAppleMusic.h"
#import "DZSongAnalysis.h"
#import "DZAutoMix.h"
#import "DZTransitionFX.h"

@interface DZRAudioPlayer : NSObject
- (double)crossFadeDuration;
- (double)playbackDuration;
- (double)playbackElapsedTime;
- (id)currentTrack;
- (void)applyCrossFadeDurationForNextTrackChange;
@end

@interface DZRAudioTrackController : NSObject
- (double)totalDuration;
@end

// (not @synchronized on Deezer's classes: that would link against their symbols)
static NSObject *lockObj(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static NSMutableDictionary<NSString *, DZSongInfo *> *sApple, *sOwn;   // by ISRC
static NSMutableSet<NSString *> *sLoaded, *sAsking, *sCompared;
static NSMutableDictionary<NSString *, NSNumber *> *sLogged;           // pair -> planned value last logged
static __weak DZRAudioPlayer *sPlayer;
static NSString *sPendingA, *sPendingB;                                // the pair Deezer asked about last
static NSString *sLastPlan;
static NSUInteger sLearnedHere;
static _Atomic double sLastPlanned;   // the crossfade AutoMix last gave Deezer
static _Atomic double sPlannedAttack; // how fast the next song comes in for that crossfade
static __thread BOOL tRealSetting;    // inside our own hook: -crossFadeDuration reports Deezer's setting

static BOOL autoMixOn(void) { return DZPrefBool(kDZAutoMix); }

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// Consecutive tracks of one album (track n then n + 1, or the next disc's
// first): Deezer plays them gapless with its crossfade on, so AutoMix does too.
static BOOL sameAlbumInOrder(id a, id b) {
    id pa = kv(a, @"albumId") ? a : kv(a, @"playableObject"), pb = kv(b, @"albumId") ? b : kv(b, @"playableObject");
    id albumA = kv(pa, @"albumId"), albumB = kv(pb, @"albumId");
    NSString *x = [albumA description], *y = [albumB description];
    if (!albumA || !albumB || !x.length || ![x isEqualToString:y]) return NO;
    NSInteger ta = [kv(pa, @"trackNumber") integerValue], tb = [kv(pb, @"trackNumber") integerValue];
    NSInteger da = [kv(pa, @"discNumber") integerValue], db = [kv(pb, @"discNumber") integerValue];
    if (ta <= 0 || tb <= 0) return NO;
    return (da == db && tb == ta + 1) || (db == da + 1 && tb == 1);
}

// DeezerTrack, or a DZRDownloadableObject wrapping one
static NSString *isrcOf(id t) {
    id v = kv(t, @"isrc");
    if (![v isKindOfClass:[NSString class]]) v = kv(kv(t, @"playableObject"), @"isrc");
    return [v isKindOfClass:[NSString class]] && [v length] >= 10 ? v : nil;
}

static NSString *titleOf(id t) {
    id v = kv(t, @"title");
    if (![v isKindOfClass:[NSString class]]) v = kv(kv(t, @"playableObject"), @"title");
    return [v isKindOfClass:[NSString class]] ? v : @"?";
}

#pragma mark - knowledge

static void ensureLoaded(NSString *isrc) {
    if (!isrc) return;
    @synchronized (lockObj()) {
        if ([sLoaded containsObject:isrc]) return;
        [sLoaded addObject:isrc];
    }
    DZSongInfo *apple = DZSongInfoLoad(isrc, @"apple"), *own = DZSongInfoLoad(isrc, @"deezit");
    @synchronized (lockObj()) {
        if (apple) sApple[isrc] = apple;
        if (own) sOwn[isrc] = own;
    }
}

static DZSongInfo *knowledge(NSString *isrc, NSString **note) {
    if (!isrc) return nil;
    ensureLoaded(isrc);
    DZSongInfo *apple, *own;
    @synchronized (lockObj()) {
        apple = sApple[isrc];
        own = sOwn[isrc];
    }
    return DZSongInfoMerge(apple, own, note);
}

// Once per song, when both analyses exist: how Deezit's compares with Apple's.
static void compareAnalyses(NSString *isrc, NSString *title) {
    DZSongInfo *apple, *own;
    @synchronized (lockObj()) {
        apple = sApple[isrc];
        own = sOwn[isrc];
        if (!apple || !own || [sCompared containsObject:isrc]) return;
        [sCompared addObject:isrc];
    }
    NSNumber *fa = [apple firstBarFrom:0], *fo = [own firstBarFrom:0];
    DZLog("automix: \"%@\" Deezit vs Apple: length %.1f / %.1f s · music ends %.1f / %.1f s · %.0f / %.0f bpm · first bar %.2f / %.2f s · %lu / %lu bars",
          title ?: isrc, own.duration, apple.duration, own.musicEnd, apple.musicEnd, own.bpm, apple.bpm,
          fo ? fo.doubleValue : -1, fa ? fa.doubleValue : -1, (unsigned long)own.bars.count, (unsigned long)apple.bars.count);
}

// After new knowledge of a song in the pair Deezer is about to play: let
// Deezer ask again (it does so itself on track and queue changes), unless the
// change is already close.
static void refreshIfPending(NSString *isrc) {
    DZRAudioPlayer *p = sPlayer;
    if (!p || !autoMixOn() || !isrc) return;
    @synchronized (lockObj()) {
        if (![isrc isEqual:sPendingA] && ![isrc isEqual:sPendingB]) return;
    }
    if (![p respondsToSelector:@selector(applyCrossFadeDurationForNextTrackChange)]) return;
    double left = 0;
    @try { left = [p playbackDuration] - [p playbackElapsedTime]; } @catch (NSException *e) { return; }
    if (left < 15) return;
    [p applyCrossFadeDurationForNextTrackChange];
}

#pragma mark - Apple's analysis

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

static void askApple(NSString *isrc, NSString *title) {
    if (!isrc) return;
    ensureLoaded(isrc);
    @synchronized (lockObj()) {
        if (sApple[isrc] || [sAsking containsObject:isrc]) return;
        [sAsking addObject:isrc];
    }
    if (DZAppleMissingRecently(isrc)) {
        @synchronized (lockObj()) { [sAsking removeObject:isrc]; }
        return;
    }
    NSString *path = [NSString stringWithFormat:@"songs?filter%%5Bisrc%%5D=%@&include=audio-analysis&extend%%5Baudio-analysis%%5D=fades",
                      [isrc stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]];
    DZAppleCatalogGet(path, ^(NSData *data, NSInteger status) {
        DZSongInfo *info = nil;
        if (data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *songs = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            NSDictionary *song = [songs isKindOfClass:[NSArray class]] ? songs.firstObject : nil;
            if ([song isKindOfClass:[NSDictionary class]]) {
                NSArray *included = [json[@"included"] isKindOfClass:[NSArray class]] ? json[@"included"] : @[];
                NSDictionary *attrs = [song[@"attributes"] isKindOfClass:[NSDictionary class]] ? song[@"attributes"] : nil;
                NSDictionary *aa = related(song, @"audio-analysis", included).firstObject[@"attributes"];
                info = DZSongInfoFromApple(aa, [attrs[@"durationInMillis"] doubleValue] / 1000.0);
            }
            if (info) DZSongInfoSave(info, isrc);
            else DZAppleMarkMissing(isrc);
        }
        @synchronized (lockObj()) {
            [sAsking removeObject:isrc];
            if (info) sApple[isrc] = info;
        }
        if (info) {
            DZLog("automix: Apple's analysis of \"%@\": %.1f s, %.0f bpm, %lu bars, fade-out at %.1f s", title, info.duration,
                  info.bpm, (unsigned long)info.bars.count, info.musicEnd);
            compareAnalyses(isrc, title);
            dispatch_async(dispatch_get_main_queue(), ^{ refreshIfPending(isrc); });
        } else {
            DZLog("automix: Apple has no analysis of \"%@\" (%@, HTTP %ld)", title, isrc, (long)status);
        }
    });
}

#pragma mark - planning

static void logPlan(NSString *key, double value, NSString *line) {
    @synchronized (lockObj()) {
        NSNumber *last = sLogged[key];
        sLastPlan = line;
        if (last && fabs(last.doubleValue - value) < 0.05) return;
        sLogged[key] = @(value);
    }
    DZLog("automix: %@", line);
}

#pragma mark - learning a song as Deezer decodes it

// The C effects state of one song, freed with it.
@interface DZFXBox : NSObject {
@public
    DZFXState *state;
}
@end

@implementation DZFXBox
- (void)dealloc {
    DZFXStateDestroy(state);
}
@end

@interface DZTrackListen : NSObject
@property (nonatomic, copy) NSString *isrc, *title;
@property (nonatomic, strong) DZSongAnalyzer *analyzer;
@property (nonatomic, weak) id controller;   // the DZRAudioTrackController decoding it
@property (nonatomic) BOOL off;    // not from the start, seeked, already known, unusable audio
@property (nonatomic) BOOL done;
@property (nonatomic) double time;           // song time (s) of the next buffer it schedules
@property (nonatomic, strong) DZFXBox *fx;   // transition effects, made when needed
@end

@implementation DZTrackListen
@end

static void *kListenKey = &kListenKey;

static void beginListening(id controller, id track, double startPosition) {
    if (!autoMixOn()) {
        objc_setAssociatedObject(controller, kListenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    DZTrackListen *l = [DZTrackListen new];
    l.isrc = isrcOf(track);
    l.title = titleOf(track);
    l.controller = controller;
    l.time = startPosition > 0 ? startPosition : 0;
    if (!l.isrc || startPosition > 0.05) {
        l.off = YES;
    } else {
        ensureLoaded(l.isrc);
        @synchronized (lockObj()) { l.off = sOwn[l.isrc] != nil; }   // learned already
    }
    objc_setAssociatedObject(controller, kListenKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void stopListening(id controller, unsigned long long toFrame, double sampleRate) {
    DZTrackListen *l = objc_getAssociatedObject(controller, kListenKey);
    if (!l) return;
    @synchronized (l) {
        // the buffers scheduled from now on start where the seek went
        if (toFrame != ULLONG_MAX && sampleRate > 1000) l.time = toFrame / sampleRate;
        else if (toFrame == ULLONG_MAX) l.time = 0;   // repeat: back to the start
        // a seek to the very start before anything was decoded changes nothing
        if (toFrame == 0 && (!l.analyzer || l.analyzer.seconds < 0.5)) return;
        l.off = YES;
    }
}

static void learn(DZTrackListen *l, DZSongAnalyzer *an, double expected) {
    double heard = an.seconds;
    if (heard < 30 || (expected > 0 && heard < expected - 8)) {
        DZLog("automix: \"%@\" not learned: %.0f of %.0f s decoded", l.title, heard, expected);
        return;
    }
    CFTimeInterval t0 = CACurrentMediaTime();
    DZSongInfo *info = [an finish];
    double took = (CACurrentMediaTime() - t0) * 1000;
    if (!info) {
        DZLog("automix: \"%@\": no music found to learn from", l.title);
        return;
    }
    DZSongInfoSave(info, l.isrc);
    @synchronized (lockObj()) {
        sOwn[l.isrc] = info;
        sLearnedHere++;
    }
    NSNumber *first = [info firstBarFrom:0];
    DZLog("automix: learned \"%@\": %.1f s, music %.1f-%.1f s, %.0f bpm (sure %.2f), %lu bars, first at %.2f s · %.0f ms",
          l.title, info.duration, info.musicStart, info.musicEnd, info.bpm, info.beatConfidence,
          (unsigned long)info.bars.count, first ? first.doubleValue : -1, took);
    compareAnalyses(l.isrc, l.title);
    NSString *isrc = l.isrc;
    dispatch_async(dispatch_get_main_queue(), ^{ refreshIfPending(isrc); });
}

// One buffer of the song into its analysis; the last one starts the learning.
static void feed(DZTrackListen *l, AVAudioPCMBuffer *pb, unsigned int frames, BOOL end) {
    DZSongAnalyzer *an = nil;
    @synchronized (l) {
        if (l.off || l.done) return;
        if (pb.format.commonFormat != AVAudioPCMFormatFloat32 || pb.format.isInterleaved || !pb.floatChannelData) {
            l.off = YES;
            return;
        }
        if (!l.analyzer) l.analyzer = [[DZSongAnalyzer alloc] initWithSampleRate:pb.format.sampleRate];
        frames = MIN(frames, pb.frameCapacity);
        if (frames) [l.analyzer addChannels:pb.floatChannelData count:(int)pb.format.channelCount frames:(int)frames stride:(int)pb.stride];
        if (!end) return;
        l.done = YES;
        an = l.analyzer;
    }
    double expected = 0;
    id controller = l.controller;
    @try { expected = controller ? [(DZRAudioTrackController *)controller totalDuration] : 0; } @catch (NSException *e) {}
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ learn(l, an, expected); });
}

#pragma mark - transitions

// The transition planned for the pair Deezer will change to next. A's effects
// run on A's buffers by A's time (they're scheduled ~3 s ahead, so before the
// change starts); B's only once Deezer has really started the crossfade
// (`natural`: its release began), never after a skip.
@interface DZTransition : NSObject
@property (nonatomic, copy) NSString *isrcA, *isrcB, *titleA, *titleB;
@property (nonatomic) DZFXPlan fx;
@property (nonatomic) BOOL natural;
@end

@implementation DZTransition
@end

static DZTransition *sTransition;   // under lockObj()

static NSString *styleName(DZFXStyle s) {
    switch (s) {
        case DZFXBassSwap: return @"bass swap";
        case DZFXEchoOut: return @"echo out";
        case DZFXFilterFade: return @"filter fade";
        default: return @"crossfade";
    }
}

// A's bar line where its music winds down (nil without bars).
static NSNumber *landingBar(DZSongInfo *a, double end) {
    NSNumber *pick = nil;
    for (NSNumber *bar in a.bars) {
        if (bar.doubleValue > end + 0.3) break;
        pick = bar;
    }
    return pick;
}

// Picks the transition for A then B and its crossfade length (what Deezer is
// told): bass swap when the tempos are within 6 % (half / double time counts),
// echo out when A has bars, else a filter fade. -1 without knowledge of A.
static double planTransition(DZSongInfo *a, DZSongInfo *b, double durationA, DZFXPlan *fx, double *attack, NSString **why) {
    memset(fx, 0, sizeof(*fx));
    if (!a) return -1;
    double dur = durationA > 1 ? durationA : a.duration;
    if (dur < 20) return -1;
    double end = a.musicEnd > 0 && a.musicEnd <= dur ? a.musicEnd : dur;
    double beatA = a.bpm > 30 ? 60.0 / a.bpm : 0;
    NSNumber *land = landingBar(a, end);
    double lead = 0;
    NSUInteger firstB = NSNotFound;
    if (b) {
        for (NSUInteger i = 0; i < b.bars.count; i++)
            if (b.bars[i].doubleValue >= MAX(0, b.musicStart - 0.05)) { firstB = i; break; }
        lead = firstB != NSNotFound ? b.bars[firstB].doubleValue : b.musicStart;
        lead = MAX(0, MIN(8, lead));
    }
    double ratio = 0;
    if (a.bpm > 30 && b.bpm > 30) {
        ratio = b.bpm / a.bpm;
        while (ratio > 1.5) ratio /= 2;
        while (ratio < 0.75) ratio *= 2;
    }
    fx->durationA = dur;
    fx->beatA = beatA;

    // bass swap: B plays 2-4 bars without bass, then the bass changes hands on A's bar line
    if (land && beatA > 0 && ratio > 0 && fabs(ratio - 1) <= 0.06 && firstB != NSNotFound) {
        int n = fabs(ratio - 1) <= 0.02 ? 4 : 2;
        for (; n >= 2; n -= 2) {
            if (firstB + n >= b.bars.count) continue;
            double swapB = b.bars[firstB + n].doubleValue;
            double swap = land.doubleValue;
            double d = dur - (swap - swapB);
            // a long outro: swap on a later bar of A
            if (d > 20) {
                for (NSNumber *bar in a.bars) {
                    if (dur - (bar.doubleValue - swapB) <= 20) { swap = bar.doubleValue; d = dur - (swap - swapB); break; }
                }
            }
            if (d >= 3 && d <= 20 && swap - swapB > 15) {
                fx->style = DZFXBassSwap;
                fx->start = swap - swapB;
                fx->swap = swap;
                fx->swapB = swapB;
                fx->length = d;
                *attack = MIN(2.0, d / 4);
                if (why) *why = [NSString stringWithFormat:@"bass swap on A's bar at %.2f s = B's bar %d at %.2f s (tempo %.0f / %.0f bpm), B starts at %.1f s",
                                 swap, n, swapB, a.bpm, b.bpm, fx->start];
                return d;
            }
        }
    }
    // echo out: A's last beats echo and A drops out on the bar B's first downbeat lands on
    if (land && beatA > 0) {
        double swap = land.doubleValue, d = dur - (swap - lead);
        if (d > 12) {
            for (NSNumber *bar in a.bars) {
                if (dur - (bar.doubleValue - lead) <= 12) { swap = bar.doubleValue; d = dur - (swap - lead); break; }
            }
        }
        if (d < 1.5) d = 1.5;
        fx->style = DZFXEchoOut;
        fx->start = dur - d;
        fx->swap = fx->start + lead;
        fx->swapB = lead;
        fx->length = d;
        *attack = 0.3;
        if (why) *why = [NSString stringWithFormat:@"echo out on A's bar at %.2f s (%.0f bpm, echo every %.2f s), B's first bar at %.2f s",
                         fx->swap, a.bpm, 0.75 * beatA, lead];
        return d;
    }
    // filter fade, timed like the plain crossfade
    NSString *plain = nil;
    double d = DZPlanCrossfade(a, b, durationA, &plain);
    if (d < 0) return -1;
    d = MAX(3, MIN(10, d));
    fx->style = DZFXFilterFade;
    fx->start = dur - d;
    fx->swap = fx->start;
    fx->length = d;
    *attack = MAX(1.0, MIN(3.0, 0.4 * d));
    if (why) *why = [NSString stringWithFormat:@"filter fade over %.1f s (%@)", d, plain];
    return d;
}

static void applyTransition(DZTrackListen *l, AVAudioPCMBuffer *buffer, double t0) {
    if (!l.isrc || !autoMixOn()) return;
    DZTransition *tr;
    @synchronized (lockObj()) { tr = sTransition; }
    if (!tr) return;
    DZFXPlan p = tr.fx;
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    double t1 = t0 + buffer.frameLength / sr;
    DZFXRole role;
    if ([l.isrc isEqualToString:tr.isrcA]) {
        if (t1 < p.start - 2) return;   // not there yet
        role = DZFXRoleA;
    } else if ([l.isrc isEqualToString:tr.isrcB]) {
        if (!tr.natural || t0 > p.length + 2) return;
        role = DZFXRoleB;
    } else {
        return;
    }
    if (buffer.format.commonFormat != AVAudioPCMFormatFloat32 || buffer.format.isInterleaved || !buffer.floatChannelData) return;
    @synchronized (l) {
        if (!l.fx) {
            l.fx = [DZFXBox new];
            l.fx->state = DZFXStateCreate(sr);
        }
        DZFXProcess(l.fx->state, &p, role, buffer.floatChannelData, (int)buffer.format.channelCount,
                    (int)buffer.frameLength, (int)buffer.stride, t0);
    }
}

// Deezer 11.27.0 decodes into CommonAudio.StereoBufferList, not an
// AVAudioPCMBuffer, then copies that into the AVAudioPCMBuffer it schedules on
// the song's player node. So a read only marks, on its thread, which song the
// next scheduled buffer belongs to; the buffer probe hands that buffer over
// (DZAutoMixScheduledBuffer) and the node remembers the song.
static __thread __unsafe_unretained DZTrackListen *tPending;
static __thread BOOL tPendingEnd;
static void *kNodeListenKey = &kNodeListenKey;
static _Atomic long sUnlinked, sLinked;

static void listen(id controller, id buffer, unsigned int frames, BOOL end) {
    DZTrackListen *l = objc_getAssociatedObject(controller, kListenKey);
    if (!l) return;
    if ([buffer isKindOfClass:[AVAudioPCMBuffer class]]) {
        feed(l, buffer, frames, end);
        return;
    }
    // always linked (not only while learning): the transition effects need
    // each scheduled buffer's song and position
    tPending = l;
    tPendingEnd = end;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DZLog("automix: Deezer decodes into %@: learning from the buffers it schedules instead",
              buffer ? NSStringFromClass([buffer class]) : @"nil");
    });
}

void DZAutoMixScheduledBuffer(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer) {
    if (!node || !buffer) return;
    DZTrackListen *l = tPending;
    BOOL end = tPendingEnd;
    tPending = nil;
    tPendingEnd = NO;
    if (l) {
        if (objc_getAssociatedObject(node, kNodeListenKey) != l)
            objc_setAssociatedObject(node, kNodeListenKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_add(&sLinked, 1);
    } else {
        l = objc_getAssociatedObject(node, kNodeListenKey);
        if (atomic_fetch_add(&sUnlinked, 1) == 400 && atomic_load(&sLinked) == 0)
            DZLog("automix: Deezer's reads and schedules happen on different threads: Deezit can't learn songs");
    }
    if (!l) return;
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    double t0;
    @synchronized (l) {
        t0 = l.time;
        l.time = t0 + buffer.frameLength / sr;
    }
    feed(l, buffer, buffer.frameLength, end);   // analysis hears the song as it is
    applyTransition(l, buffer, t0);
}

#pragma mark - hooks

%group DZAutoMixPlan

%hook DZRAudioPlayer

// Deezer's crossfade setting. When the next song starts,
// -playNextTrackWithChange: checks it: at 0 it pauses the current song on the
// spot instead of fading it out (-releasePlayback), whatever the pair's
// crossfade was. So while AutoMix has planned a crossfade for the pair coming
// up, Deezer is told the setting is that crossfade. Pairs AutoMix leaves
// gapless (and Deezit's own reads) see the real setting.
- (double)crossFadeDuration {
    double real = %orig;
    if (tRealSetting || !autoMixOn()) return real;
    double planned = atomic_load(&sLastPlanned);
    return planned > 0 ? MAX(real, planned) : real;
}

- (double)crossFadeDurationForPlayable:(id)a followedByPlayable:(id)b {
    BOOL wasReal = tRealSetting;
    tRealSetting = YES;
    double d = %orig;
    tRealSetting = wasReal;
    if (!autoMixOn()) return d;
    sPlayer = self;
    NSString *ia = isrcOf(a), *ib = isrcOf(b);
    @synchronized (lockObj()) {
        sPendingA = ia;
        sPendingB = ib;
    }
    askApple(ia, titleOf(a));
    askApple(ib, titleOf(b));
    double setting = 0;
    tRealSetting = YES;
    @try { setting = [self crossFadeDuration]; } @catch (NSException *e) {}
    tRealSetting = wasReal;
    NSString *key = [NSString stringWithFormat:@"%@>%@", ia ?: titleOf(a), ib ?: titleOf(b)];
    if (setting > 0.05 && d < 0.05) {
        logPlan(key, d, [NSString stringWithFormat:@"\"%@\" → \"%@\": Deezer keeps this pair gapless", titleOf(a), titleOf(b)]);
        return d;
    }
    if (sameAlbumInOrder(a, b)) {
        logPlan(key, 0, [NSString stringWithFormat:@"\"%@\" → \"%@\": next track of the same album, kept gapless", titleOf(a), titleOf(b)]);
        atomic_store(&sLastPlanned, 0.0);
        return 0;
    }
    NSString *noteA, *noteB, *why;
    DZSongInfo *infoA = knowledge(ia, &noteA), *infoB = knowledge(ib, &noteB);
    double durA = 0;
    if (ia && [isrcOf([self currentTrack]) isEqualToString:ia]) {
        @try { durA = [self playbackDuration]; } @catch (NSException *e) {}
    }
    DZFXPlan fx;
    double attack = 0;
    double planned = planTransition(infoA, infoB, durA, &fx, &attack, &why);
    if (planned < 0) {
        logPlan(key, d, [NSString stringWithFormat:@"\"%@\" → \"%@\": nothing known about \"%@\" yet, Deezer's %.1f s",
                         titleOf(a), titleOf(b), titleOf(a), d]);
        atomic_store(&sLastPlanned, 0.0);
        @synchronized (lockObj()) { sTransition = nil; }
        return d;
    }
    logPlan(key, planned, [NSString stringWithFormat:@"\"%@\" → \"%@\": %@, %.1f s · %@ · A: %@, B: %@",
                           titleOf(a), titleOf(b), styleName(fx.style), planned, why, noteA ?: @"-", noteB ?: @"nothing known"]);
    atomic_store(&sLastPlanned, planned);
    atomic_store(&sPlannedAttack, attack);
    @synchronized (lockObj()) {
        // same pair: keep whether its crossfade has started
        BOOL started = sTransition.natural && [sTransition.isrcA isEqual:ia] && [sTransition.isrcB isEqual:ib];
        DZTransition *tr = [DZTransition new];
        tr.isrcA = ia;
        tr.isrcB = ib;
        tr.titleA = titleOf(a);
        tr.titleB = titleOf(b);
        tr.fx = fx;
        tr.natural = started;
        sTransition = tr;
    }
    return planned;
}

// Deezer starts the crossfade (A's release; B starts right after): from now
// on B's buffers get their part of the transition.
- (void)mixablePlaybackWillStartPlaybackRelease:(id)mixable withDuration:(double)duration {
    if (autoMixOn() && duration > 0.05) {
        DZTransition *tr;
        @synchronized (lockObj()) {
            tr = sTransition;
            tr.natural = YES;
        }
        if (tr) DZLog("automix: %@ from \"%@\" into \"%@\" (%.1f s)", styleName(tr.fx.style), tr.titleA, tr.titleB, duration);
    }
    %orig;
}

%end

%end

%group DZAutoMixListen

%hook DZRAudioTrackController

- (void)prepareToPlayTrack:(id)track ofCollection:(id)collection {
    beginListening(self, track, 0);
    %orig;
}

- (void)prepareToPlayTrack:(id)track ofCollection:(id)collection startingTimePosition:(double)position userInfo:(id)info {
    beginListening(self, track, position);
    %orig;
}

- (void)loadTrack:(id)track ofCollection:(id)collection startingTimePosition:(double)position {
    beginListening(self, track, position);
    %orig;
}

- (unsigned int)readAudioIntoBuffer:(id)buffer frames:(unsigned int)frames endReached:(BOOL *)endReached {
    unsigned int n = %orig;
    if (objc_getAssociatedObject(self, kListenKey)) listen(self, buffer, n, endReached ? *endReached : NO);
    return n;
}

- (void)audioDecoderDidSeek:(id)decoder fromFrame:(unsigned long long)from toFrame:(unsigned long long)to sampleRate:(float)rate {
    stopListening(self, to, rate);
    %orig;
}

// Deezer fades the next song in over the whole crossfade (its
// applyCrossFadeDurationForNextTrackChange gives both fades the same length).
// AutoMix brings it in as its transition needs: within 2 s for a bass swap
// (B plays without bass until the swap), 0.3 s for an echo out (B lands on
// the downbeat), 1-3 s for a filter fade. The current song still fades over
// the whole overlap.
- (void)setPlaybackAttackDuration:(double)d {
    double planned = atomic_load(&sLastPlanned);
    if (autoMixOn() && planned > 0 && fabs(d - planned) < 0.01) {
        double attack = atomic_load(&sPlannedAttack);
        if (attack <= 0) attack = MAX(1.0, MIN(3.0, 0.4 * d));
        static double lastLogged;
        if (fabs(lastLogged - d) > 0.01) {
            lastLogged = d;
            DZLog("automix: next song fades in over %.1f s (Deezer asked %.1f s)", attack, d);
        }
        %orig(attack);
        return;
    }
    %orig;
}

- (void)rewindByRepeating:(BOOL)repeating userInfo:(id)info {
    stopListening(self, ULLONG_MAX, 0);
    %orig;
}

%end

%end

static BOOL hasMethod(Class c, SEL s, const char *typePrefix) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    const char *t = m ? method_getTypeEncoding(m) : NULL;
    return t && strncmp(t, typePrefix, strlen(typePrefix)) == 0;
}

void DZAutoMixInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!DZPrefBool(kDZAudioHook)) return;
        sApple = [NSMutableDictionary dictionary];
        sOwn = [NSMutableDictionary dictionary];
        sLoaded = [NSMutableSet set];
        sAsking = [NSMutableSet set];
        sCompared = [NSMutableSet set];
        sLogged = [NSMutableDictionary dictionary];

        Class player = objc_getClass("DZRAudioPlayer");
        if (!hasMethod(player, @selector(crossFadeDurationForPlayable:followedByPlayable:), "d") ||
            !hasMethod(player, @selector(crossFadeDuration), "d") ||
            !hasMethod(player, @selector(mixablePlaybackWillStartPlaybackRelease:withDuration:), "v")) {
            DZLog("automix: DZRAudioPlayer not as expected, AutoMix off");
            return;
        }
        %init(DZAutoMixPlan);

        Class controller = objc_getClass("DZRAudioTrackController");
        SEL need[] = { @selector(prepareToPlayTrack:ofCollection:), @selector(prepareToPlayTrack:ofCollection:startingTimePosition:userInfo:),
                       @selector(loadTrack:ofCollection:startingTimePosition:), @selector(audioDecoderDidSeek:fromFrame:toFrame:sampleRate:),
                       @selector(rewindByRepeating:userInfo:), @selector(setPlaybackAttackDuration:) };
        BOOL ok = hasMethod(controller, @selector(readAudioIntoBuffer:frames:endReached:), "I");
        for (size_t i = 0; i < sizeof(need) / sizeof(need[0]); i++) ok = ok && hasMethod(controller, need[i], "v");
        if (ok) %init(DZAutoMixListen);
        else DZLog("automix: DZRAudioTrackController not as expected, Deezit won't learn songs (Apple's analysis only)");

        DZLog("automix: ready, %@ · Deezit has learned %lu songs, Apple's analysis saved for %lu",
              autoMixOn() ? @"on" : @"off (••• → Playback Controls)", (unsigned long)DZSongInfoCount(@"deezit"),
              (unsigned long)DZSongInfoCount(@"apple"));
    });
}

NSUInteger DZAutoMixLearnedSongs(void) {
    return DZSongInfoCount(@"deezit");
}

NSString *DZAutoMixStatus(void) {
    NSString *last;
    NSUInteger here;
    @synchronized (lockObj()) {
        last = sLastPlan;
        here = sLearnedHere;
    }
    return [NSString stringWithFormat:@"automix: %@ · learned %lu this session · last: %@", autoMixOn() ? @"on" : @"off",
            (unsigned long)here, last ?: @"no song change yet"];
}
