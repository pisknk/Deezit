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
//
// Transitions (DZTransitionFX) are applied to the buffers each song schedules,
// by song position. While the two overlap, B plays at A's tempo
// (DZTimeStretch: its buffers are scheduled time-stretched, Deezer's clock
// counts B's own frames so lyrics stay with B) and eases back to its own tempo
// once A is gone. A mixes out on a phrase before its music winds down; A's
// last part then plays on silently, so Deezer's fade-out of A (its player
// node's volume) is held off and the transition shapes A's level instead.
// Deezer starts B when A's remaining time drops below the crossfade, checked
// as each ~83 ms buffer of A finishes: Deezer is told 0.12 s more than the
// plan, and B starts with the few ms of silence that put it exactly on time.

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
#import "DZTimeStretch.h"

@interface DZRAudioPlayer : NSObject
- (double)crossFadeDuration;
- (double)playbackDuration;
- (double)playbackElapsedTime;
- (id)currentTrack;
- (void)applyCrossFadeDurationForNextTrackChange;
@end

@interface DZRAudioTrackController : NSObject
- (double)totalDuration;
- (double)elapsedDuration;
- (id)track;
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
static BOOL sHoldReady;               // Deezer's fade-out of A can be held off (setVolume: hooked)
static const double kStartPad = 0.12; // told to Deezer on top of the plan, so B never starts late (s)
static const double kMaxOverlap = 50; // longest overlap AutoMix plans (s)

static BOOL autoMixOn(void) { return DZPrefBool(kDZAutoMix); }

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// Consecutive tracks of one album (track n then n + 1, or the next disc's
// first). Deezer plays them gapless with its crossfade on; AutoMix mixes them
// like any pair unless one runs straight into the next (flowsInto).
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

// A's music goes on to its very end and B's starts at once: one piece of music
// split in two tracks (a live album, a medley), so it stays gapless.
static BOOL flowsInto(DZSongInfo *a, DZSongInfo *b) {
    if (!a || a.duration <= 0 || a.musicEnd <= 0) return NO;
    BOOL aRunsOut = a.duration - a.musicEnd < 1.0;
    BOOL bStartsAtOnce = !b || b.musicStart < 0.5;
    return aRunsOut && bStartsAtOnce;
}

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

// The time-stretcher of the song coming in, freed with it.
@interface DZStretchBox : NSObject {
@public
    DZStretch *st;
}
@end

@implementation DZStretchBox
- (void)dealloc {
    DZStretchDestroy(st);
}
@end

@class DZTransition;

@interface DZTrackListen : NSObject
@property (nonatomic, copy) NSString *isrc, *title;
@property (nonatomic, strong) DZSongAnalyzer *analyzer;
@property (nonatomic, weak) id controller;   // the DZRAudioTrackController decoding it
@property (nonatomic) BOOL off;    // not from the start, seeked, already known, unusable audio
@property (nonatomic) BOOL done;
@property (nonatomic) double time;           // song time (s) of the next buffer it schedules
@property (nonatomic) double seekedTo;       // where the last seek went (s), -1 none
@property (nonatomic, strong) DZFXBox *fx;   // transition effects, made when needed
// as the song coming in (B)
@property (nonatomic) int joinState;         // 0 first buffer not seen yet, 1 came in with a change, 2 not
@property (nonatomic, weak) DZTransition *joined;   // the change it came in with
@property (nonatomic) int padFrames;         // silence before its first buffer (puts it on time)
@property (nonatomic) double stretchRate, glideFrom, glideTo;   // its tempo plan (song time)
@property (nonatomic, strong) DZStretchBox *stretch;            // while its tempo is changed
// as the song going out (A)
@property (nonatomic) float steadyVolume;    // its node's volume before Deezer's fade-out
@property (nonatomic) BOOL loggedHold;
@property (nonatomic) unsigned long serial;  // its number in sListens
@end

@implementation DZTrackListen
@end

static void *kListenKey = &kListenKey;

// Every song being decoded, by number (weak: a song that's gone looks up as
// nil). What a read leaves for the schedule that follows is this number, never
// a pointer: a schedule can come much later on another thread (Karaoke
// schedules on its own queue), by when the song may be gone.
static NSMapTable<NSNumber *, DZTrackListen *> *sListens;   // under lockObj()
static unsigned long sListenSerial;                          // under lockObj()

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
    l.seekedTo = startPosition > 0.05 ? startPosition : -1;
    @synchronized (lockObj()) {
        l.serial = ++sListenSerial;
        [sListens setObject:l forKey:@(l.serial)];
    }
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
        l.seekedTo = l.time;
        // a song coming in that's moved: no more tempo change or transition on it
        if (l.joinState == 1 || l.stretch) {
            l.joinState = 2;
            l.stretch = nil;
            l.padFrames = 0;
        }
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

// A transition between A and B. Planned when Deezer asks about the pair
// (sTransition); once Deezer starts it (A's release began: `natural`) it's
// also the running one (sActive) until it's over, because Deezer asks about
// the next pair (B, C) as soon as B starts. A's effects run on A's buffers by
// A's time (they're scheduled ~3 s ahead, so before the change starts); B's
// only on a B that came in with the change, never after a skip.
@interface DZTransition : NSObject
@property (nonatomic, copy) NSString *isrcA, *isrcB, *titleA, *titleB;
@property (nonatomic) DZFXPlan fx;
@property (nonatomic) double stretchRate, glideFrom, glideTo;   // B's tempo plan (B's time)
@property (nonatomic) BOOL natural;
@property (nonatomic) double naturalAt;   // CACurrentMediaTime() it started
@property (nonatomic) double early;       // B started this much before the plan (s): padded with silence
@property (nonatomic) BOOL misaligned;    // started elsewhere than planned (a seek into it): Deezer's crossfade
@end

@implementation DZTransition
@end

static DZTransition *sTransition;   // under lockObj()
static DZTransition *sActive;       // under lockObj()

// The change running now (started within its overlap plus a margin).
static DZTransition *activeTransition(void) {
    DZTransition *tr;
    @synchronized (lockObj()) { tr = sActive; }
    if (!tr || !tr.natural || CACurrentMediaTime() - tr.naturalAt > tr.fx.length + 30) return nil;
    return tr;
}

static NSString *styleName(DZFXStyle s) {
    switch (s) {
        case DZFXBassSwap: return @"bass swap";
        case DZFXEchoOut: return @"echo out";
        case DZFXFilterFade: return @"filter fade";
        default: return @"crossfade";
    }
}

// A's bar line to mix out on: the last phrase start (every 8th bar from A's
// first) in the 32 s before A's music winds down, else its last bar there.
// Nil without bars.
static NSNumber *mixOutBar(DZSongInfo *a, double end, BOOL *phrase) {
    NSNumber *last = nil, *start = nil;
    NSUInteger i = 0;
    for (NSNumber *bar in a.bars) {
        if (bar.doubleValue > end + 0.3) break;
        last = bar;
        if (i % 8 == 0 && bar.doubleValue >= end - 32) start = bar;
        i++;
    }
    if (phrase) *phrase = start != nil;
    return start ?: last;
}

// One bar of A at `at` (s), from its bar lines, else four beats.
static double barOf(DZSongInfo *a, double at, double beat) {
    NSNumber *prev = nil;
    for (NSNumber *bar in a.bars) {
        if (prev && bar.doubleValue > at + 0.01) {
            double d = bar.doubleValue - prev.doubleValue;
            if (d > 0.5 && d < 8) return d;
            break;
        }
        prev = bar;
    }
    return beat > 0 ? 4 * beat : 2;
}

// Picks the transition for A then B, its overlap (s) and B's tempo plan:
//   bass swap  tempos within 10 % (half / double time counts; 6 % without
//              tempo matching): B comes in 2-8 bars (at most ~17 s) before A's
//              phrase without bass, the bass changes hands on A's bar line, A
//              fades over 2 bars
//   echo out   A has bars: A's last beats echo, A drops out on B's first downbeat
//   filter fade otherwise
// While they overlap B plays at A's tempo, then eases back to its own over a
// few bars. -1 without knowledge of A.
static double planTransition(DZSongInfo *a, DZSongInfo *b, double durationA, DZFXPlan *fx, double *rateOut,
                             double *glideFrom, double *glideTo, double *attack, NSString **why) {
    memset(fx, 0, sizeof(*fx));
    *rateOut = 1;
    *glideFrom = *glideTo = 0;
    if (!a) return -1;
    double dur = durationA > 1 ? durationA : a.duration;
    if (dur < 20) return -1;
    double end = a.musicEnd > 0 && a.musicEnd <= dur ? a.musicEnd : dur;
    double beatA = a.bpm > 30 ? 60.0 / a.bpm : 0;
    BOOL phrase = NO;
    NSNumber *land = mixOutBar(a, end, &phrase);
    double lead = 0;
    NSUInteger firstB = NSNotFound;
    if (b) {
        for (NSUInteger i = 0; i < b.bars.count; i++)
            if (b.bars[i].doubleValue >= MAX(0, b.musicStart - 0.05)) { firstB = i; break; }
        lead = firstB != NSNotFound ? b.bars[firstB].doubleValue : b.musicStart;
        lead = MAX(0, MIN(8, lead));
    }
    // B's tempo over A's, half / double time folded in
    double ratio = 0;
    if (a.bpm > 30 && b.bpm > 30) {
        ratio = b.bpm / a.bpm;
        while (ratio > 1.5) ratio /= 2;
        while (ratio < 0.75) ratio *= 2;
    }
    double off = ratio > 0 ? fabs(ratio - 1) : 1;
    BOOL tempoOn = DZPrefBool(kDZAutoMixTempo);
    // B's frames per frame heard: B at A's tempo
    double rate = tempoOn && off > 0.002 && off <= 0.10 ? 1.0 / ratio : 1.0;
    BOOL inTempo = off <= 0.002 || rate != 1.0;
    double barB = b.bpm > 30 ? 4 * 60.0 / b.bpm : 2;
    fx->durationA = dur;
    fx->beatA = beatA;
    fx->ownGainA = sHoldReady;
    // rate is B's frames per frame heard: B plays at rate x its speed
    NSString *tempo = rate != 1.0 ? [NSString stringWithFormat:@", B at %.1f %% speed", 100 * rate] : @"";
    NSString *where = phrase ? @"phrase" : @"bar";

    // bass swap
    if (land && beatA > 0 && ratio > 0 && firstB != NSNotFound && (inTempo || off <= 0.06)) {
        int ns[3] = { 8, 4, 2 };
        if (!inTempo) { ns[0] = off <= 0.02 ? 4 : 2; ns[1] = 2; ns[2] = 0; }
        for (int k = 0; k < 3 && ns[k] > 0; k++) {
            int n = ns[k];
            if (firstB + n >= b.bars.count) continue;
            double swapB = b.bars[firstB + n].doubleValue;
            double heardB = swapB / rate;   // B's lead-in as heard
            // at most ~17 s of B under A (8 bars at 120 bpm; 4 at 70)
            if (heardB > 17) continue;
            double swap = land.doubleValue;
            where = phrase ? @"phrase" : @"bar";
            double d = dur - (swap - heardB);
            // a long outro after the phrase: swap on a later bar of A
            if (d > kMaxOverlap) {
                for (NSNumber *bar in a.bars) {
                    if (bar.doubleValue <= swap) continue;
                    if (dur - (bar.doubleValue - heardB) <= kMaxOverlap) {
                        swap = bar.doubleValue;
                        d = dur - (swap - heardB);
                        where = @"bar";
                        break;
                    }
                }
            }
            if (d < 3 || d > kMaxOverlap || swap - heardB < 15) continue;
            fx->style = DZFXBassSwap;
            fx->start = swap - heardB;
            fx->swap = swap;
            fx->swapB = swapB;
            fx->length = d;
            fx->tailA = 2 * barOf(a, swap, beatA);
            if (rate != 1.0) {
                // A's gone after its 2-bar tail; then 8 bars back to B's own tempo
                *rateOut = rate;
                *glideFrom = swapB + fx->tailA * rate;
                *glideTo = *glideFrom + MIN(20.0, 8 * barB);
            }
            *attack = MIN(2.0, MAX(0.3, heardB / 4));
            if (why) *why = [NSString stringWithFormat:@"bass swap on A's %@ at %.2f s = B's bar %d at %.2f s (%.0f / %.0f bpm%@), B starts at %.1f s, A out over %.1f s",
                             where, swap, n, swapB, a.bpm, b.bpm, tempo, fx->start, fx->tailA];
            return d;
        }
    }
    // echo out: A's last beats echo and A drops out on the bar B's first downbeat lands on
    if (land && beatA > 0) {
        double heardLead = lead / rate;
        double swap = land.doubleValue, d = dur - (swap - heardLead);
        if (d > 16) {
            for (NSNumber *bar in a.bars) {
                if (bar.doubleValue <= swap) continue;
                if (dur - (bar.doubleValue - heardLead) <= 16) { swap = bar.doubleValue; d = dur - (swap - heardLead); where = @"bar"; break; }
            }
        }
        if (d < 1.5) d = 1.5;
        fx->style = DZFXEchoOut;
        fx->start = dur - d;
        fx->swap = fx->start + heardLead;
        fx->swapB = lead;
        fx->length = d;
        *attack = 0.3;
        // B's intro under A's last beats: at A's tempo, then 4 bars back to its own
        if (rate != 1.0 && lead > beatA) {
            *rateOut = rate;
            *glideFrom = lead;
            *glideTo = lead + MIN(12.0, 4 * barB);
        } else {
            tempo = @"";
        }
        if (why) *why = [NSString stringWithFormat:@"echo out on A's %@ at %.2f s (%.0f bpm, echo every %.2f s), B's first bar at %.2f s%@",
                         where, fx->swap, a.bpm, 0.75 * beatA, lead, tempo];
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

static BOOL usableBuffer(AVAudioPCMBuffer *b) {
    AVAudioFormat *f = b.format;
    return f.commonFormat == AVAudioPCMFormatFloat32 && !f.isInterleaved && b.floatChannelData &&
           f.channelCount >= 1 && f.channelCount <= 2;
}

// On B's first buffer: did it come in with the change Deezer just started?
// Then it gets its side of the transition, its silence pad and its tempo plan.
static void joinChange(DZTrackListen *l, AVAudioPCMBuffer *buffer, double t0) {
    @synchronized (l) {
        if (l.joinState != 0) return;
        l.joinState = 2;
    }
    if (!l.isrc || !autoMixOn() || t0 > 0.05) return;
    DZTransition *tr = activeTransition(), *planned;
    @synchronized (lockObj()) { planned = sTransition; }
    if (!tr || ![l.isrc isEqualToString:tr.isrcB] || tr.misaligned) {
        if (planned && [l.isrc isEqualToString:planned.isrcB] && !planned.natural)
            DZLog("automix: \"%@\" started without its crossfade (a skip, or queued before the change): no transition on it", l.title);
        return;
    }
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    BOOL stretch = tr.stretchRate > 0 && fabs(tr.stretchRate - 1) > 1e-4 && usableBuffer(buffer) &&
                   buffer.frameLength >= 2700;
    @synchronized (l) {
        l.joinState = 1;
        l.joined = tr;
        l.padFrames = (int)lround(MAX(0, tr.early) * sr);
        if (stretch) {
            DZStretch *st = DZStretchCreate((int)buffer.format.channelCount, sr, 0);
            if (st) {
                l.stretch = [DZStretchBox new];
                l.stretch->st = st;
                l.stretchRate = tr.stretchRate;
                l.glideFrom = tr.glideFrom;
                l.glideTo = tr.glideTo;
            }
        }
    }
    DZLog("automix: \"%@\" comes in %.0f ms ahead, padded%@", l.title, tr.early * 1000,
          l.stretch ? [NSString stringWithFormat:@", at %.1f %% speed until %.1f s, its own tempo from %.1f s",
                       100 * tr.stretchRate, tr.glideFrom, tr.glideTo] : @"");
}

static void applyTransition(DZTrackListen *l, AVAudioPCMBuffer *buffer, double t0) {
    if (!l.isrc || !autoMixOn()) return;
    DZTransition *active = activeTransition(), *planned;
    @synchronized (lockObj()) { planned = sTransition; }
    int joined;
    double seeked;
    @synchronized (l) {
        joined = l.joinState;
        seeked = l.seekedTo;
    }
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    double t1 = t0 + buffer.frameLength / sr;
    DZTransition *tr;
    DZFXRole role;
    if (joined == 1 && active && l.joined == active && [l.isrc isEqualToString:active.isrcB]) {
        tr = active;
        role = DZFXRoleB;
    } else if (active && [l.isrc isEqualToString:active.isrcA]) {
        tr = active;
        role = DZFXRoleA;
    } else if (planned && [l.isrc isEqualToString:planned.isrcA]) {
        tr = planned;
        role = DZFXRoleA;
    } else {
        return;
    }
    DZFXPlan p = tr.fx;
    if (tr.misaligned) return;
    if (role == DZFXRoleA) {
        if (t1 < p.start - 2) return;          // not there yet
        if (seeked >= p.start - 3) return;     // jumped into it: Deezer's own crossfade
    } else if (t0 > MAX(p.length * 1.2, p.swapB + 1) + 2) {
        return;
    }
    if (!usableBuffer(buffer)) return;
    @synchronized (l) {
        if (!l.fx) {
            l.fx = [DZFXBox new];
            l.fx->state = DZFXStateCreate(sr);
        }
        DZFXProcess(l.fx->state, &p, role, buffer.floatChannelData, (int)buffer.format.channelCount,
                    (int)buffer.frameLength, (int)buffer.stride, t0);
    }
}

static double rateAt(DZTrackListen *l, double t) {
    double r = l.stretchRate;
    if (r <= 0 || fabs(r - 1) < 1e-4 || t >= l.glideTo) return 1;
    if (t <= l.glideFrom || l.glideTo <= l.glideFrom) return r;
    return r + (1 - r) * (t - l.glideFrom) / (l.glideTo - l.glideFrom);
}

// B's buffer as it's scheduled: the silence pad before the first one, then
// time-stretched while its tempo is changed. Returns `buffer` when untouched.
static AVAudioPCMBuffer *shapeIncoming(DZTrackListen *l, AVAudioPCMBuffer *buffer, double t0, BOOL end) {
    int pad;
    DZStretchBox *box;
    @synchronized (l) {
        if (l.joinState != 1) return buffer;
        pad = l.padFrames;
        l.padFrames = 0;
        box = l.stretch;
    }
    if (!pad && !box) return buffer;
    if (!usableBuffer(buffer)) {
        @synchronized (l) { l.stretch = nil; }
        return buffer;
    }
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    int frames = (int)buffer.frameLength, ch = (int)buffer.format.channelCount, stride = (int)buffer.stride;
    double rate = 1;
    BOOL finish = NO;
    int cap = pad + frames;
    if (box) {
        rate = rateAt(l, t0 + 0.5 * frames / sr);
        // back at its own tempo, at its end, or a short buffer (after a seek): hand back to the song as is
        finish = end || frames < 1200 || fabs(rate - 1) < 1e-4;
        cap = pad + DZStretchCapacity(box->st, frames, rate);
    }
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:buffer.format frameCapacity:(AVAudioFrameCount)cap];
    if (!out || (int)out.stride != stride) {
        @synchronized (l) { l.stretch = nil; }
        return buffer;
    }
    float *const *dst = out.floatChannelData;
    for (int c = 0; c < ch; c++) memset(dst[c], 0, sizeof(float) * (size_t)pad * (size_t)stride);
    float *shifted[2];
    for (int c = 0; c < ch; c++) shifted[c] = dst[c] + (long)pad * stride;
    int n;
    if (!box) {
        for (int c = 0; c < ch; c++) {
            const float *src = buffer.floatChannelData[c];
            for (int i = 0; i < frames; i++) shifted[c][(long)i * stride] = src[(long)i * stride];
        }
        n = frames;
    } else if (finish) {
        n = DZStretchFinish(box->st, (const float *const *)buffer.floatChannelData, frames, stride, shifted, stride, cap - pad);
        @synchronized (l) { l.stretch = nil; }
        DZLog("automix: \"%@\" back at its own tempo at %.1f s", l.title, t0);
    } else {
        n = DZStretchProcess(box->st, (const float *const *)buffer.floatChannelData, frames, stride, rate, shifted, stride, cap - pad);
    }
    out.frameLength = (AVAudioFrameCount)(pad + n);
    if (out.frameLength == 0) return buffer;   // can't happen with >= 1200 frames in; never schedule nothing
    return out;
}

#pragma mark - holding Deezer's fade-out of A

// Deezer fades a song out by its player node's volume
// (DZRAudioTrackController -audioMixingVolumeDidUpdate: -> -setVolume:). While
// a transition that shapes A itself runs, A's node keeps the volume it had.
static void (*sOrigSetVolume)(id, SEL, float);
static void *kNodeListenKey = &kNodeListenKey;

static float heldVolume(DZTrackListen *l, float v) {
    DZTransition *tr = autoMixOn() ? activeTransition() : nil;
    BOOL hold = tr && !tr.misaligned && tr.fx.ownGainA && l.isrc && [l.isrc isEqualToString:tr.isrcA] && l.joined != tr;
    BOOL log = NO;
    float steady;
    @synchronized (l) {
        if (!hold || l.steadyVolume <= 0.001f) {
            if (!hold) l.steadyVolume = v;
            return v;
        }
        steady = l.steadyVolume;
        if (!l.loggedHold) {
            l.loggedHold = YES;
            log = YES;
        }
    }
    if (log) DZLog("automix: holding \"%@\" at volume %.2f through the transition (Deezer asked %.2f)", l.title, steady, v);
    return steady;
}

static void dzSetVolume(id self, SEL _cmd, float v) {
    if (sHoldReady && [self isKindOfClass:[AVAudioPlayerNode class]]) {
        DZTrackListen *l = objc_getAssociatedObject(self, kNodeListenKey);
        if (l) v = heldVolume(l, v);
    }
    sOrigSetVolume(self, _cmd, v);
}

static void installVolumeHold(void) {
    SEL sel = @selector(setVolume:);
    Class owner = Nil;
    for (Class c = [AVAudioPlayerNode class]; c && !owner; c = class_getSuperclass(c)) {
        unsigned n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned i = 0; i < n; i++)
            if (method_getName(ms[i]) == sel) { owner = c; break; }
        free(ms);
    }
    Method m = owner ? class_getInstanceMethod(owner, sel) : NULL;
    const char *types = m ? method_getTypeEncoding(m) : NULL;
    if (!types || types[0] != 'v' || !strchr(types, 'f')) {
        DZLog("automix: no -setVolume: on AVAudioPlayerNode (%s): Deezer fades the songs out itself", types ?: "none");
        return;
    }
    sOrigSetVolume = (void (*)(id, SEL, float))method_getImplementation(m);
    method_setImplementation(m, (IMP)dzSetVolume);
    sHoldReady = YES;
}

// Deezer 11.27.0 decodes into CommonAudio.StereoBufferList, not an
// AVAudioPCMBuffer, then copies that into the AVAudioPCMBuffer it schedules on
// the song's player node. So a read only notes, on its thread, which song the
// next scheduled buffer belongs to (the song's number << 1 | end of song); the
// buffer probe hands that buffer over (DZAutoMixScheduledBuffer) and the node
// remembers the song. Karaoke takes the note with the buffer to its own queue
// and puts it back there right before scheduling it.
static __thread uint64_t tPending;
static _Atomic long sUnlinked, sLinked;

uint64_t DZAutoMixTakePending(void) {
    uint64_t t = tPending;
    tPending = 0;
    return t;
}

void DZAutoMixSetPending(uint64_t note) {
    tPending = note;
}

static void listen(id controller, id buffer, unsigned int frames, BOOL end) {
    DZTrackListen *l = objc_getAssociatedObject(controller, kListenKey);
    if (!l) return;
    if ([buffer isKindOfClass:[AVAudioPCMBuffer class]]) {
        feed(l, buffer, frames, end);
        return;
    }
    // always linked (not only while learning): the transition effects need
    // each scheduled buffer's song and position
    tPending = ((uint64_t)l.serial << 1) | (end ? 1 : 0);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DZLog("automix: Deezer decodes into %@: learning from the buffers it schedules instead",
              buffer ? NSStringFromClass([buffer class]) : @"nil");
    });
}

AVAudioPCMBuffer *DZAutoMixScheduledBuffer(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer, BOOL canReplace) {
    if (!node || !buffer) return buffer;
    uint64_t note = tPending;
    tPending = 0;
    BOOL end = (note & 1) != 0;
    DZTrackListen *l = nil;
    if (note) {
        @synchronized (lockObj()) { l = [sListens objectForKey:@(note >> 1)]; }
    }
    if (l) {
        if (objc_getAssociatedObject(node, kNodeListenKey) != l)
            objc_setAssociatedObject(node, kNodeListenKey, l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_fetch_add(&sLinked, 1);
    } else {
        l = objc_getAssociatedObject(node, kNodeListenKey);
        if (atomic_fetch_add(&sUnlinked, 1) == 400 && atomic_load(&sLinked) == 0)
            DZLog("automix: Deezer's reads and schedules happen on different threads: Deezit can't learn songs");
    }
    if (!l) return buffer;
    double sr = buffer.format.sampleRate > 1000 ? buffer.format.sampleRate : 44100;
    double t0;
    @synchronized (l) {
        t0 = l.time;
        l.time = t0 + buffer.frameLength / sr;
    }
    feed(l, buffer, buffer.frameLength, end);   // analysis hears the song as it is
    joinChange(l, buffer, t0);
    applyTransition(l, buffer, t0);
    return canReplace ? shapeIncoming(l, buffer, t0, end) : buffer;
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
    NSString *noteA, *noteB, *why;
    DZSongInfo *infoA = knowledge(ia, &noteA), *infoB = knowledge(ib, &noteB);
    // album tracks in order (and pairs Deezer keeps gapless) are mixed too,
    // unless the first runs straight into the next
    BOOL deezerGapless = setting > 0.05 && d < 0.05, album = sameAlbumInOrder(a, b);
    if (deezerGapless || album) {
        NSString *reason = !infoA ? [NSString stringWithFormat:@"nothing known about \"%@\" yet", titleOf(a)]
                         : flowsInto(infoA, infoB) ? @"it runs straight into the next" : nil;
        if (reason) {
            logPlan(key, 0, [NSString stringWithFormat:@"\"%@\" → \"%@\": %@, kept gapless (%@)", titleOf(a), titleOf(b),
                             album ? @"next track of the same album" : @"Deezer plays this pair gapless", reason]);
            atomic_store(&sLastPlanned, 0.0);
            @synchronized (lockObj()) { sTransition = nil; }
            return deezerGapless ? d : 0;
        }
    }
    double durA = 0;
    if (ia && [isrcOf([self currentTrack]) isEqualToString:ia]) {
        @try { durA = [self playbackDuration]; } @catch (NSException *e) {}
    }
    DZFXPlan fx;
    double attack = 0, rate = 1, glideFrom = 0, glideTo = 0;
    double planned = planTransition(infoA, infoB, durA, &fx, &rate, &glideFrom, &glideTo, &attack, &why);
    if (planned < 0) {
        logPlan(key, d, [NSString stringWithFormat:@"\"%@\" → \"%@\": nothing known about \"%@\" yet, Deezer's %.1f s",
                         titleOf(a), titleOf(b), titleOf(a), d]);
        atomic_store(&sLastPlanned, 0.0);
        @synchronized (lockObj()) { sTransition = nil; }
        return d;
    }
    logPlan(key, planned, [NSString stringWithFormat:@"\"%@\" → \"%@\": %@, %.1f s · %@ · A: %@, B: %@",
                           titleOf(a), titleOf(b), styleName(fx.style), planned, why, noteA ?: @"-", noteB ?: @"nothing known"]);
    // Deezer starts B once A's remaining time is at most this, checked as each
    // of A's buffers finishes: a little more than planned, so B is never late
    // (it starts with the silence that puts it on time)
    double told = planned + kStartPad;
    DZTransition *running = activeTransition();
    if (running && [running.isrcA isEqual:ia] && [running.isrcB isEqual:ib]) return told;   // already under way
    atomic_store(&sLastPlanned, told);
    atomic_store(&sPlannedAttack, attack);
    DZTransition *tr = [DZTransition new];
    tr.isrcA = ia;
    tr.isrcB = ib;
    tr.titleA = titleOf(a);
    tr.titleB = titleOf(b);
    tr.fx = fx;
    tr.stretchRate = rate;
    tr.glideFrom = glideFrom;
    tr.glideTo = glideTo;
    @synchronized (lockObj()) { sTransition = tr; }
    return told;
}

// Deezer starts the crossfade (A's release; B starts right after, from the
// same buffer completion of A). `mixable` is A's track controller: where A
// is now says how far ahead of the plan B starts (padded with silence), or
// that the change started somewhere else (a seek into it).
- (void)mixablePlaybackWillStartPlaybackRelease:(id)mixable withDuration:(double)duration {
    if (autoMixOn() && duration > 0.05) {
        DZTransition *tr;
        @synchronized (lockObj()) { tr = sTransition; }
        NSString *isrc = nil;
        double elapsed = -1;
        @try {
            if ([mixable respondsToSelector:@selector(track)]) isrc = isrcOf([(DZRAudioTrackController *)mixable track]);
            if ([mixable respondsToSelector:@selector(elapsedDuration)]) elapsed = [(DZRAudioTrackController *)mixable elapsedDuration];
        } @catch (NSException *e) {}
        // only a change from the planned A: when a new song is picked Deezer
        // fades the old one out too, from a controller that may no longer say
        // which track it was (its clock back at 0). Unnamed counts only on time.
        double early = elapsed >= 0 ? tr.fx.start - elapsed : 0;
        BOOL onTime = elapsed >= 0 && early >= -0.03 && early <= kStartPad + 0.15;
        BOOL fromA = isrc ? [isrc isEqualToString:tr.isrcA] && elapsed >= 0 : onTime;
        if (tr && !tr.natural && !fromA) {
            DZLog("automix: Deezer fades out %@ at %.2f s (%.1f s) instead of changing from \"%@\" (a song picked?): no transition",
                  isrc ? @"a song" : @"a song it doesn't name", elapsed, duration, tr.titleA);
        } else if (tr && !tr.natural) {
            BOOL misaligned = !onTime;
            tr.early = misaligned ? 0 : MAX(0, early);
            tr.misaligned = misaligned;
            tr.naturalAt = CACurrentMediaTime();
            tr.natural = YES;
            @synchronized (lockObj()) { sActive = tr; }
            DZLog("automix: %@ from \"%@\" into \"%@\" (%.1f s) · A at %.2f s, planned %.2f s%@", styleName(tr.fx.style),
                  tr.titleA, tr.titleB, duration, elapsed, tr.fx.start,
                  misaligned ? @" · not where planned (a seek?): Deezer's own crossfade" : @"");
        }
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
// the downbeat), 1-3 s for a filter fade. The current song's fade-out is held
// off while the transition shapes it (installVolumeHold).
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
        sListens = [NSMapTable strongToWeakObjectsMapTable];
        sLogged = [NSMutableDictionary dictionary];

        Class player = objc_getClass("DZRAudioPlayer");
        if (!hasMethod(player, @selector(crossFadeDurationForPlayable:followedByPlayable:), "d") ||
            !hasMethod(player, @selector(crossFadeDuration), "d") ||
            !hasMethod(player, @selector(mixablePlaybackWillStartPlaybackRelease:withDuration:), "v")) {
            DZLog("automix: DZRAudioPlayer not as expected, AutoMix off");
            return;
        }
        %init(DZAutoMixPlan);
        installVolumeHold();

        Class controller = objc_getClass("DZRAudioTrackController");
        SEL need[] = { @selector(prepareToPlayTrack:ofCollection:), @selector(prepareToPlayTrack:ofCollection:startingTimePosition:userInfo:),
                       @selector(loadTrack:ofCollection:startingTimePosition:), @selector(audioDecoderDidSeek:fromFrame:toFrame:sampleRate:),
                       @selector(rewindByRepeating:userInfo:), @selector(setPlaybackAttackDuration:) };
        BOOL ok = hasMethod(controller, @selector(readAudioIntoBuffer:frames:endReached:), "I");
        for (size_t i = 0; i < sizeof(need) / sizeof(need[0]); i++) ok = ok && hasMethod(controller, need[i], "v");
        if (ok) %init(DZAutoMixListen);
        else DZLog("automix: DZRAudioTrackController not as expected, Deezit won't learn songs (Apple's analysis only)");

        DZLog("automix: ready, %@ · tempo matching %@ · fade-out hold %@ · Deezit has learned %lu songs, Apple's analysis saved for %lu",
              autoMixOn() ? @"on" : @"off (••• → Playback Controls)", DZPrefBool(kDZAutoMixTempo) ? @"on" : @"off",
              sHoldReady ? @"ready" : @"unavailable", (unsigned long)DZSongInfoCount(@"deezit"),
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
