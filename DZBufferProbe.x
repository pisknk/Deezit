// Probe for the vocal-removal ("Sing") feature: how does Deezer feed audio to
// its AVAudioPlayerNodes?
//
// An ML vocal separator works on chunks of a few seconds, so it can't run in
// the realtime render callback. If Deezer schedules decoded PCM buffers far
// enough ahead of playback, each buffer can be separated when it's scheduled
// (timing stays exact, lyrics stay in sync). If it schedules just in time, the
// separator has to sit in the graph with a delay. This logs what's needed to
// decide:
//   - buffer size, PCM format, scheduling options / atTime use
//   - how much audio is queued ahead of playback after each schedule
//     (frames scheduled minus frames whose completion handler has fired)
//   - how many distinct buffer objects Deezer cycles through (a reused pool
//     means it refills buffers after they complete)
//   - which thread schedules, and when nodes play / pause / stop
// Summaries every 5 s for the first 30 s after a node starts, then every 30 s.
// Only installed with the audio hook on (debug-panel kill switch).

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <float.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAutoMixProbe.h"

@interface DZNodeStats : NSObject {
@public
    _Atomic(long long) outstandingFrames;   // scheduled, completion not fired yet
    _Atomic(long) completed;
}
@property (nonatomic) NSUInteger serial;
@property (nonatomic) long scheduled;
@property (nonatomic, copy) NSString *format;
@property (nonatomic) double sampleRate;
@property (nonatomic) CFTimeInterval sessionStart, lastSummary;
@property (nonatomic) NSUInteger detailLeft;      // individual schedule lines still to log this session
// current summary window
@property (nonatomic) NSUInteger winBuffers, winAtTime, winOptions;
@property (nonatomic) AVAudioFrameCount winMinFrames, winMaxFrames;
@property (nonatomic) double winMinAhead, winMaxAhead;
@property (nonatomic, strong) NSMutableSet<NSValue *> *winObjects;
@property (nonatomic, copy) NSString *winHow;
@end

@implementation DZNodeStats
- (void)resetWindow {
    self.winBuffers = self.winAtTime = self.winOptions = 0;
    self.winMinFrames = UINT32_MAX;
    self.winMaxFrames = 0;
    self.winMinAhead = DBL_MAX;
    self.winMaxAhead = 0;
    self.winObjects = [NSMutableSet set];
    self.winHow = nil;
}
@end

static void *kDZStatsKey = &kDZStatsKey;
static NSUInteger sNodes;
static __thread int sInSchedule;      // AVFoundation's own variants may call each other
static NSString *sLastSummary;

static NSString *formatName(AVAudioFormat *f) {
    NSString *kind;
    switch (f.commonFormat) {
        case AVAudioPCMFormatFloat32: kind = @"float32"; break;
        case AVAudioPCMFormatFloat64: kind = @"float64"; break;
        case AVAudioPCMFormatInt16: kind = @"int16"; break;
        case AVAudioPCMFormatInt32: kind = @"int32"; break;
        default: kind = @"other"; break;
    }
    return [NSString stringWithFormat:@"%.0f Hz %@ %u ch %@", f.sampleRate, kind, (unsigned)f.channelCount,
            f.isInterleaved ? @"interleaved" : @"non-interleaved"];
}

static DZNodeStats *statsFor(AVAudioPlayerNode *node) {
    DZNodeStats *s = objc_getAssociatedObject(node, kDZStatsKey);
    if (s) return s;
    @synchronized ([DZNodeStats class]) {
        s = objc_getAssociatedObject(node, kDZStatsKey);
        if (!s) {
            s = [DZNodeStats new];
            s.serial = ++sNodes;
            // a node can be scheduled before its first play: start the clock now
            s.sessionStart = s.lastSummary = CACurrentMediaTime();
            [s resetWindow];
            objc_setAssociatedObject(node, kDZStatsKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return s;
}

static void startSession(AVAudioPlayerNode *node, NSString *what) {
    DZNodeStats *s = statsFor(node);
    @synchronized (s) {
        s.sessionStart = s.lastSummary = CACurrentMediaTime();
        s.detailLeft = 4;
        [s resetWindow];
    }
    DZLog("buffer probe: player #%lu %@ (queued %.2f s)", (unsigned long)s.serial, what,
          s.sampleRate > 0 ? atomic_load(&s->outstandingFrames) / s.sampleRate : 0.0);
}

// Logs the window when it's due: every 5 s for 30 s after play, then every 30 s.
static void maybeSummarize(DZNodeStats *s, CFTimeInterval now) {
    double interval = now - s.sessionStart < 30 ? 5 : 30;
    if (now - s.lastSummary < interval || !s.winBuffers) return;
    NSString *line = [NSString stringWithFormat:
        @"player #%lu · %@ · last %.0f s: %lu buffers of %u-%u frames (%.0f-%.0f ms) via %@ · "
        @"queued ahead %.2f-%.2f s · %lu distinct buffer objects · with atTime %lu, with options %lu · "
        @"total scheduled %ld, completed %ld",
        (unsigned long)s.serial, s.format, now - s.lastSummary, (unsigned long)s.winBuffers,
        (unsigned)s.winMinFrames, (unsigned)s.winMaxFrames,
        s.sampleRate > 0 ? s.winMinFrames * 1000.0 / s.sampleRate : 0, s.sampleRate > 0 ? s.winMaxFrames * 1000.0 / s.sampleRate : 0,
        s.winHow, s.winMinAhead == DBL_MAX ? 0 : s.winMinAhead, s.winMaxAhead,
        (unsigned long)s.winObjects.count, (unsigned long)s.winAtTime, (unsigned long)s.winOptions,
        s.scheduled, atomic_load(&s->completed)];
    s.lastSummary = now;
    [s resetWindow];
    @synchronized ([DZNodeStats class]) { sLastSummary = line; }
    DZLog("buffer probe: %@", line);
}

// Records one schedule call (the wrapped completion handler, below, keeps the
// queued-ahead count and then calls Deezer's own handler).
static void noteSchedule(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer, AVAudioTime *when,
                         AVAudioPlayerNodeBufferOptions options, NSString *how) {
    DZNodeStats *s = statsFor(node);
    AVAudioFrameCount frames = buffer.frameLength;
    long long queued = atomic_fetch_add(&s->outstandingFrames, (long long)frames) + frames;
    CFTimeInterval now = CACurrentMediaTime();
    @synchronized (s) {
        if (!s.format) {
            s.format = formatName(buffer.format);
            s.sampleRate = buffer.format.sampleRate;
        }
        double ahead = s.sampleRate > 0 ? queued / s.sampleRate : 0;
        s.scheduled++;
        s.winBuffers++;
        s.winMinFrames = MIN(s.winMinFrames, frames);
        s.winMaxFrames = MAX(s.winMaxFrames, frames);
        s.winMinAhead = MIN(s.winMinAhead, ahead);
        s.winMaxAhead = MAX(s.winMaxAhead, ahead);
        if (when) s.winAtTime++;
        if (options) s.winOptions++;
        [s.winObjects addObject:[NSValue valueWithPointer:(__bridge const void *)buffer]];
        if (!s.winHow) s.winHow = how;
        if (s.detailLeft > 0) {
            s.detailLeft--;
            DZLog("buffer probe: player #%lu schedules %u frames (%.0f ms) via %@ on %@ · buffer %p · atTime %@ · options %lu · queued ahead %.2f s",
                  (unsigned long)s.serial, (unsigned)frames, s.sampleRate > 0 ? frames * 1000.0 / s.sampleRate : 0, how,
                  NSThread.isMainThread ? @"main" : (NSThread.currentThread.name.length ? NSThread.currentThread.name : @"background"),
                  (__bridge void *)buffer, when ? [NSString stringWithFormat:@"sample %lld", when.sampleTime] : @"none",
                  (unsigned long)options, ahead);
        }
        maybeSummarize(s, now);
    }
    // around a song change: this buffer's level, and when it will be heard
    if (DZAutoMixProbeWants() && s.sampleRate > 0)
        DZAutoMixProbeBuffer(s.serial, buffer, (queued - (long long)frames) / s.sampleRate);
}

static AVAudioNodeCompletionHandler wrapPlain(AVAudioPlayerNode *node, AVAudioFrameCount frames, AVAudioNodeCompletionHandler orig) {
    DZNodeStats *s = statsFor(node);
    return ^{
        atomic_fetch_sub(&s->outstandingFrames, (long long)frames);
        atomic_fetch_add(&s->completed, 1);
        if (orig) orig();
    };
}

static AVAudioPlayerNodeCompletionHandler wrapTyped(AVAudioPlayerNode *node, AVAudioFrameCount frames,
                                                    AVAudioPlayerNodeCompletionHandler orig) {
    DZNodeStats *s = statsFor(node);
    __block BOOL counted = NO;   // typed handlers can fire once per callback type
    return ^(AVAudioPlayerNodeCompletionCallbackType type) {
        if (!counted) {
            counted = YES;
            atomic_fetch_sub(&s->outstandingFrames, (long long)frames);
            atomic_fetch_add(&s->completed, 1);
        }
        if (orig) orig(type);
    };
}

%group DZBufferProbeHooks

%hook AVAudioPlayerNode

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionHandler:(AVAudioNodeCompletionHandler)handler {
    if (sInSchedule || !buffer) { %orig; return; }
    sInSchedule++;
    noteSchedule(self, buffer, nil, 0, @"scheduleBuffer:completionHandler:");
    %orig(buffer, wrapPlain(self, buffer.frameLength, handler));
    sInSchedule--;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options completionHandler:(AVAudioNodeCompletionHandler)handler {
    if (sInSchedule || !buffer) { %orig; return; }
    sInSchedule++;
    noteSchedule(self, buffer, when, options, @"scheduleBuffer:atTime:options:completionHandler:");
    %orig(buffer, when, options, wrapPlain(self, buffer.frameLength, handler));
    sInSchedule--;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)type completionHandler:(AVAudioPlayerNodeCompletionHandler)handler {
    if (sInSchedule || !buffer) { %orig; return; }
    sInSchedule++;
    noteSchedule(self, buffer, nil, 0, @"scheduleBuffer:completionCallbackType:completionHandler:");
    %orig(buffer, type, wrapTyped(self, buffer.frameLength, handler));
    sInSchedule--;
}

- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options completionCallbackType:(AVAudioPlayerNodeCompletionCallbackType)type completionHandler:(AVAudioPlayerNodeCompletionHandler)handler {
    if (sInSchedule || !buffer) { %orig; return; }
    sInSchedule++;
    noteSchedule(self, buffer, when, options, @"scheduleBuffer:atTime:options:completionCallbackType:completionHandler:");
    %orig(buffer, when, options, type, wrapTyped(self, buffer.frameLength, handler));
    sInSchedule--;
}

- (void)scheduleFile:(AVAudioFile *)file atTime:(AVAudioTime *)when completionHandler:(AVAudioNodeCompletionHandler)handler {
    DZLog("buffer probe: player #%lu schedules a whole file (%@)", (unsigned long)statsFor(self).serial, file.url.lastPathComponent);
    %orig;
}

- (void)scheduleSegment:(AVAudioFile *)file startingFrame:(AVAudioFramePosition)start frameCount:(AVAudioFrameCount)count atTime:(AVAudioTime *)when completionHandler:(AVAudioNodeCompletionHandler)handler {
    DZLog("buffer probe: player #%lu schedules a file segment (%u frames of %@)", (unsigned long)statsFor(self).serial,
          (unsigned)count, file.url.lastPathComponent);
    %orig;
}

- (void)play {
    %orig;
    startSession(self, @"play");
}

- (void)playAtTime:(AVAudioTime *)when {
    %orig;
    startSession(self, when ? @"playAtTime:" : @"playAtTime: nil");
}

- (void)pause {
    DZLog("buffer probe: player #%lu pause", (unsigned long)statsFor(self).serial);
    %orig;
}

- (void)stop {
    DZNodeStats *s = statsFor(self);
    long long queued = atomic_load(&s->outstandingFrames);
    // Deezer stops idle nodes constantly; only stops that drop audio are interesting
    if (queued > 0 && s.sampleRate > 0) {
        DZLog("buffer probe: player #%lu stop (had %.2f s queued)", (unsigned long)s.serial, queued / s.sampleRate);
    }
    %orig;
}

%end

%end

void DZBufferProbeInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!DZPrefBool(kDZAudioHook)) return;
        %init(DZBufferProbeHooks);
        DZLog("buffer probe: logging how Deezer schedules audio on its player nodes");
    });
}

NSString *DZBufferProbeStatus(void) {
    @synchronized ([DZNodeStats class]) {
        return sLastSummary ? [@"buffer probe: " stringByAppendingString:sLastSummary] : @"buffer probe: nothing scheduled yet";
    }
}
