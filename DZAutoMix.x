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

@interface DZTrackListen : NSObject
@property (nonatomic, copy) NSString *isrc, *title;
@property (nonatomic, strong) DZSongAnalyzer *analyzer;
@property (nonatomic, weak) id controller;   // the DZRAudioTrackController decoding it
@property (nonatomic) BOOL off;    // not from the start, seeked, already known, unusable audio
@property (nonatomic) BOOL done;
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
    if (!l.isrc || startPosition > 0.05) {
        l.off = YES;
    } else {
        ensureLoaded(l.isrc);
        @synchronized (lockObj()) { l.off = sOwn[l.isrc] != nil; }   // learned already
    }
    objc_setAssociatedObject(controller, kListenKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void stopListening(id controller, unsigned long long toFrame) {
    DZTrackListen *l = objc_getAssociatedObject(controller, kListenKey);
    if (!l) return;
    @synchronized (l) {
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
    @synchronized (l) {
        if (l.off || l.done) return;
    }
    if ([buffer isKindOfClass:[AVAudioPCMBuffer class]]) {
        feed(l, buffer, frames, end);
        return;
    }
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
    if (l) feed(l, buffer, buffer.frameLength, end);
}

#pragma mark - hooks

%group DZAutoMixPlan

%hook DZRAudioPlayer

- (double)crossFadeDurationForPlayable:(id)a followedByPlayable:(id)b {
    double d = %orig;
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
    @try { setting = [self crossFadeDuration]; } @catch (NSException *e) {}
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
    double planned = DZPlanCrossfade(infoA, infoB, durA, &why);
    if (planned < 0) {
        logPlan(key, d, [NSString stringWithFormat:@"\"%@\" → \"%@\": nothing known about \"%@\" yet, Deezer's %.1f s",
                         titleOf(a), titleOf(b), titleOf(a), d]);
        atomic_store(&sLastPlanned, 0.0);
        return d;
    }
    logPlan(key, planned, [NSString stringWithFormat:@"\"%@\" → \"%@\": crossfade %.1f s (Deezer's setting %.1f s) · %@ · A: %@, B: %@",
                           titleOf(a), titleOf(b), planned, setting, why, noteA ?: @"-", noteB ?: @"nothing known"]);
    atomic_store(&sLastPlanned, planned);
    return planned;
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
    stopListening(self, to);
    %orig;
}

// Deezer fades the next song in over the whole crossfade (its
// applyCrossFadeDurationForNextTrackChange gives both fades the same length),
// so with a song already winding down the middle of the overlap goes quiet.
// AutoMix's crossfades bring the next song in faster: 40 % of the overlap,
// 1 to 3 s; the current song still fades over all of it.
- (void)setPlaybackAttackDuration:(double)d {
    double planned = atomic_load(&sLastPlanned);
    if (autoMixOn() && planned > 0 && fabs(d - planned) < 0.01) {
        double attack = MAX(1.0, MIN(3.0, 0.4 * d));
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
    stopListening(self, ULLONG_MAX);
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
        if (!hasMethod(player, @selector(crossFadeDurationForPlayable:followedByPlayable:), "d")) {
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
