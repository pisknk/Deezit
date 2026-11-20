// AVAudioEngine backend (picked in docs/ANALYSIS.md for Deezer 11.27.0).
//
// Deezer plays through AVAudioEngine in its main binary (AVAudioPlayerNode,
// TimePitch, EQ, a mixer). Deezit rewires whatever feeds the engine's output
// node so every source passes through two Apple units first:
//
//     <Deezer's last node, normally the main mixer>
//         -> AVAudioUnitVarispeed   speed, pitch follows (the "slowed" sound)
//         -> Apple Reverb2          mix / room / damping
//         -> outputNode
//
// Both units stay in the graph once spliced; turning the effect off only sets
// them to bypass, so toggling never rebuilds Deezer's graph mid-song.
//
// Hooks (plain ObjC, Logos internal generator, no fishhook):
//   -connect:to:format:     Deezer connecting something to the output node
//                           (also re-splices after Deezer rebuilds its graph)
//   -prepare / -startAndReturnError:
//                           catches the implicit mainMixer -> output
//                           connection AVAudioEngine makes on its own
// Every graph change is wrapped in @try: if AVAudioEngine refuses one, Deezer's
// own connection is restored and the reason is logged, so the worst case is
// "no effect", not "no sound". The debug panel's kill switch disables all of
// this on the next launch.
//
// Everything below runs on Deezer's configuration threads, never on the
// realtime render thread, so logging and allocation here are fine.

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import "DZAudioHook.h"
#import "DZPrefs.h"
#import "DZLog.h"
#import "DZVocalUnit.h"

// Apple Reverb2 ('rvb2'), the unit AVAudioUnitReverb wraps. Used directly so
// room size and damping map onto real parameters (AVAudioUnitReverb only
// exposes factory presets + wet/dry). Parameter IDs from AudioUnitParameters.h
// (kReverb2Param_*), spelled out so the build doesn't depend on the SDK
// exposing that enum.
static const OSType kDZReverb2SubType = 'rvb2';
enum {
    kDZRv2DryWetMix = 0,          // 0 ... 100 %
    kDZRv2Gain = 1,               // -20 ... 20 dB
    kDZRv2MinDelayTime = 2,       // 0.0001 ... 1 s
    kDZRv2MaxDelayTime = 3,       // 0.0001 ... 1 s
    kDZRv2DecayTimeAt0Hz = 4,     // 0.001 ... 20 s
    kDZRv2DecayTimeAtNyquist = 5, // 0.001 ... 20 s
};

@interface DZEngineState : NSObject
@property (nonatomic) NSUInteger serial;          // "engine #n" in logs
@property (nonatomic, strong) AVAudioUnitEffect *vocals;    // Deezit's "Sing" unit, nil if it couldn't be made
@property (nonatomic, strong) AVAudioUnitVarispeed *varispeed;
@property (nonatomic, strong) AVAudioUnitEffect *reverb;
@property (nonatomic) BOOL loggedNoSource;
@property (nonatomic) BOOL gaveUp;                 // splice broke start: leave this engine alone
@property (nonatomic, copy) NSString *lastGraph;   // logged again only when it changes
@end
@implementation DZEngineState
@end

static DZAudioBackend sActive = DZAudioBackendNone;
static NSObject *sLock;
static NSHashTable<DZEngineState *> *sStates;   // weak: an engine owns its state
static NSUInteger sEnginesSeen, sSplices, sFailures;
static NSString *sLastError;
static __thread int sInside;                    // >0 while Deezit edits a graph itself
static void *kDZStateKey = &kDZStateKey;

#pragma mark - params

static void applyParams(DZEngineState *st) {
    DZAudioParams p = DZPrefsAudioParams();

    BOOL speedOn = p.enabled && fabsf(p.speed - 1.0f) > 0.001f;
    st.varispeed.rate = speedOn ? p.speed : 1.0f;
    st.varispeed.bypass = !speedOn;

    AudioUnit au = st.reverb.audioUnit;
    if (au) {
        float room = p.reverbRoom, damp = p.reverbDamp;
        float decay = 0.4f + room * room * 7.6f;                   // 0.4 s ... 8 s
        float decayHigh = fmaxf(0.05f, decay * (1.0f - 0.92f * damp)); // damping darkens the tail
        float maxDelay = 0.03f + room * 0.12f;                     // bigger room, later reflections
        AudioUnitSetParameter(au, kDZRv2DryWetMix, kAudioUnitScope_Global, 0, p.reverbMix * 100.0f, 0);
        AudioUnitSetParameter(au, kDZRv2Gain, kAudioUnitScope_Global, 0, 0.0f, 0);
        AudioUnitSetParameter(au, kDZRv2MinDelayTime, kAudioUnitScope_Global, 0, 0.008f, 0);
        AudioUnitSetParameter(au, kDZRv2MaxDelayTime, kAudioUnitScope_Global, 0, maxDelay, 0);
        AudioUnitSetParameter(au, kDZRv2DecayTimeAt0Hz, kAudioUnitScope_Global, 0, decay, 0);
        AudioUnitSetParameter(au, kDZRv2DecayTimeAtNyquist, kAudioUnitScope_Global, 0, decayHigh, 0);
    }
    st.reverb.bypass = !(p.enabled && p.reverbMix > 0.001f);
}

static void applyParamsToAll(void) {
    NSArray<DZEngineState *> *all;
    @synchronized (sLock) { all = sStates.allObjects; }
    for (DZEngineState *st in all) applyParams(st);
}

#pragma mark - bookkeeping

static void noteError(NSString *msg) {
    @synchronized (sLock) { sFailures++; sLastError = [msg copy]; }
    DZLog("audio: %@", msg);
}

static DZEngineState *stateFor(AVAudioEngine *e) {
    DZEngineState *st = objc_getAssociatedObject(e, kDZStateKey);
    if (st) return st;
    @synchronized (sLock) {
        st = objc_getAssociatedObject(e, kDZStateKey);
        if (st) return st;
        st = [DZEngineState new];
        st.serial = ++sEnginesSeen;
        st.vocals = DZVocalUnitCreate();
        st.varispeed = [AVAudioUnitVarispeed new];
        AudioComponentDescription d = { kAudioUnitType_Effect, kDZReverb2SubType, kAudioUnitManufacturer_Apple, 0, 0 };
        st.reverb = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:d];
        objc_setAssociatedObject(e, kDZStateKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sStates addObject:st];
    }
    applyParams(st);
    DZLog("audio: engine #%lu seen (%p)", (unsigned long)st.serial, (__bridge void *)e);
    return st;
}

#pragma mark - graph description (for the debug log)

// First Deezit node after Deezer's mixer: the vocals unit when there is one.
static AVAudioNode *chainHead(DZEngineState *st) {
    return st.vocals ?: (AVAudioNode *)st.varispeed;
}

static NSString *nodeName(DZEngineState *st, AVAudioNode *n) {
    if (n && n == st.vocals) return @"[Deezit vocals]";
    if (n == st.varispeed) return @"[Deezit varispeed]";
    if (n == st.reverb) return @"[Deezit reverb]";
    NSString *name = NSStringFromClass([n class]);
    if ([n isKindOfClass:[AVAudioUnit class]]) {
        NSString *unit = ((AVAudioUnit *)n).name;
        if (unit.length && ![unit isEqualToString:name]) name = [name stringByAppendingFormat:@" \"%@\"", unit];
    }
    return name;
}

static void describeUpstream(AVAudioEngine *e, DZEngineState *st, AVAudioNode *n, int depth,
                             NSMutableString *out, NSHashTable *seen) {
    if (!n || depth > 8) return;
    if ([seen containsObject:n]) { [out appendFormat:@"%*s(loop)\n", depth * 2, ""]; return; }
    [seen addObject:n];
    NSUInteger buses = n.numberOfInputs;
    if ([n isKindOfClass:[AVAudioMixerNode class]]) buses = ((AVAudioMixerNode *)n).nextAvailableInputBus;
    buses = MIN(buses, (NSUInteger)16);
    for (AVAudioNodeBus b = 0; b < buses; b++) {
        AVAudioConnectionPoint *cp = [e inputConnectionPointForNode:n inputBus:b];
        if (!cp.node) continue;
        AVAudioFormat *f = [cp.node outputFormatForBus:cp.bus];
        [out appendFormat:@"%*s<- %@ (in %lu, %.0f Hz/%u ch)\n", depth * 2, "", nodeName(st, cp.node),
                          (unsigned long)b, f.sampleRate, (unsigned)f.channelCount];
        describeUpstream(e, st, cp.node, depth + 1, out, seen);
    }
}

static NSString *describeGraph(AVAudioEngine *e, DZEngineState *st) {
    NSMutableString *s = [NSMutableString stringWithString:@"output\n"];
    describeUpstream(e, st, e.outputNode, 1, s, [NSHashTable weakObjectsHashTable]);
    NSCountedSet *kinds = [NSCountedSet set];
    for (AVAudioNode *n in e.attachedNodes) [kinds addObject:nodeName(st, n)];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [kinds.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        NSUInteger c = [kinds countForObject:k];
        [parts addObject:c > 1 ? [NSString stringWithFormat:@"%@ x%lu", k, (unsigned long)c] : k];
    }
    [s appendFormat:@"  attached: %@", [parts componentsJoinedByString:@", "]];
    return s;
}

#pragma mark - splice

// Rewires  src --(bus)--> out  into  src -> [vocals] -> varispeed -> reverb -> out.
// Returns YES when the output is connected afterwards (spliced, or Deezer's
// connection restored after a failure); NO tells the caller to run Deezer's
// original call instead.
static BOOL splice(AVAudioEngine *e, DZEngineState *st, AVAudioNode *src, AVAudioNodeBus bus,
                   AVAudioNode *out, AVAudioFormat *requested, NSString *why) {
    AVAudioFormat *srcFmt = requested ?: [src outputFormatForBus:bus];
    if (srcFmt.sampleRate <= 0 || srcFmt.channelCount != 2) {
        noteError([NSString stringWithFormat:@"engine #%lu: not splicing %@ (%@): format %.0f Hz/%u ch, need stereo",
                   (unsigned long)st.serial, nodeName(st, src), why, srcFmt.sampleRate, (unsigned)srcFmt.channelCount]);
        return NO;
    }
    // the effect units want deinterleaved float; the mixer converts for us
    AVAudioFormat *fmt = srcFmt.isStandard ? srcFmt
        : [[AVAudioFormat alloc] initStandardFormatWithSampleRate:srcFmt.sampleRate channels:2];

    BOOL ok = NO;
    sInside++;
    @try {
        if (st.vocals && st.vocals.engine != e) [e attachNode:st.vocals];
        if (st.varispeed.engine != e) [e attachNode:st.varispeed];
        if (st.reverb.engine != e) [e attachNode:st.reverb];
        [e connect:src to:chainHead(st) fromBus:bus toBus:0 format:fmt];
        if (st.vocals) [e connect:st.vocals to:st.varispeed format:fmt];
        [e connect:st.varispeed to:st.reverb format:fmt];
        [e connect:st.reverb to:out format:fmt];
        ok = YES;
    } @catch (NSException *ex) {
        noteError([NSString stringWithFormat:@"engine #%lu: splice (%@) refused: %@ - %@",
                   (unsigned long)st.serial, why, ex.name, ex.reason]);
        @try {
            [e connect:src to:out fromBus:bus toBus:0 format:requested];
            DZLog("audio: engine #%lu: Deezer's own connection restored", (unsigned long)st.serial);
            sInside--;
            return YES;
        } @catch (NSException *ex2) {
            noteError([NSString stringWithFormat:@"engine #%lu: restore failed too: %@", (unsigned long)st.serial, ex2.reason]);
            sInside--;
            return NO;
        }
    }
    sInside--;
    if (ok) {
        @synchronized (sLock) { sSplices++; }
        applyParams(st);
        DZLog("audio: engine #%lu: spliced after %@ (%@, %.0f Hz)", (unsigned long)st.serial,
              nodeName(st, src), why, fmt.sampleRate);
    }
    return ok;
}

// Undo a splice: Deezer's node goes straight back to the output and Deezit's
// units are detached. Used when the engine won't start with them in place.
static BOOL unsplice(AVAudioEngine *e, DZEngineState *st) {
    AVAudioConnectionPoint *src = [e inputConnectionPointForNode:chainHead(st) inputBus:0];
    if (!src.node) return NO;
    BOOL ok = NO;
    sInside++;
    @try {
        [e connect:src.node to:e.outputNode fromBus:src.bus toBus:0 format:nil];
        if (st.vocals.engine == e) [e detachNode:st.vocals];
        [e detachNode:st.varispeed];
        [e detachNode:st.reverb];
        ok = YES;
    } @catch (NSException *ex) {
        noteError([NSString stringWithFormat:@"engine #%lu: undoing the splice failed: %@",
                   (unsigned long)st.serial, ex.reason]);
    }
    sInside--;
    return ok;
}

// Takes only the vocals unit out (Deezer's mixer -> varispeed directly), for
// when the engine won't start with it; slowed + reverb keep working. The
// unit isn't used on this engine again.
static BOOL dropVocals(AVAudioEngine *e, DZEngineState *st) {
    AVAudioUnitEffect *vocals = st.vocals;
    if (!vocals || vocals.engine != e) return NO;
    AVAudioConnectionPoint *src = [e inputConnectionPointForNode:vocals inputBus:0];
    if (!src.node) return NO;
    BOOL ok = NO;
    sInside++;
    @try {
        AVAudioFormat *fmt = [vocals inputFormatForBus:0];
        [e connect:src.node to:st.varispeed fromBus:src.bus toBus:0 format:fmt];
        [e detachNode:vocals];
        st.vocals = nil;
        ok = YES;
    } @catch (NSException *ex) {
        noteError([NSString stringWithFormat:@"engine #%lu: removing the vocals unit failed: %@",
                   (unsigned long)st.serial, ex.reason]);
    }
    sInside--;
    return ok;
}

// The implicit mainMixer -> output connection never goes through
// -connect:to:format:, so check what feeds the output before the engine runs.
static void ensureSpliced(AVAudioEngine *e, NSString *why) {
    if (sInside || e.isRunning) return;
    if (e.isInManualRenderingMode) return;       // offline rendering, not playback
    DZEngineState *st = stateFor(e);
    if (st.gaveUp) return;
    AVAudioOutputNode *out = e.outputNode;
    AVAudioConnectionPoint *cp = [e inputConnectionPointForNode:out inputBus:0];
    if (!cp.node) {
        if (!st.loggedNoSource) {
            st.loggedNoSource = YES;
            DZLog("audio: engine #%lu: nothing feeds the output yet (%@)", (unsigned long)st.serial, why);
        }
        return;
    }
    if (cp.node == st.reverb) return;            // already ours
    splice(e, st, cp.node, cp.bus, out, nil, why);
}

static void logGraphIfChanged(AVAudioEngine *e, NSString *when) {
    DZEngineState *st = objc_getAssociatedObject(e, kDZStateKey);
    if (!st) return;
    NSString *g = describeGraph(e, st);
    if ([g isEqualToString:st.lastGraph]) return;
    st.lastGraph = g;
    DZLog("audio: engine #%lu graph at %@:\n%@", (unsigned long)st.serial, when, g);
}

#pragma mark - hooks

%group DZEngineHooks

%hook AVAudioEngine

- (void)connect:(AVAudioNode *)node1 to:(AVAudioNode *)node2 format:(AVAudioFormat *)format {
    if (sInside || !node1 || ![node2 isKindOfClass:[AVAudioOutputNode class]]) {
        %orig;
        return;
    }
    DZEngineState *st = stateFor(self);
    if (st.gaveUp || node1 == st.reverb || node1 == st.varispeed || (st.vocals && node1 == st.vocals)) {
        %orig;
        return;
    }
    DZLog("audio: engine #%lu: Deezer connects %@ -> output", (unsigned long)st.serial, nodeName(st, node1));
    if (!splice(self, st, node1, 0, node2, format, @"connect")) %orig;
}

- (void)prepare {
    ensureSpliced(self, @"prepare");
    %orig;
}

- (BOOL)startAndReturnError:(NSError **)outError {
    ensureSpliced(self, @"start");
    BOOL ok = %orig;
    if (!ok) {
        DZEngineState *st = stateFor(self);
        NSError *err = outError ? *outError : nil;
        noteError([NSString stringWithFormat:@"engine #%lu: start failed: %@ (%ld)", (unsigned long)st.serial,
                   err.localizedDescription ?: @"no error", (long)err.code]);
        // the newest unit first: without vocals, slowed + reverb may still work
        if (dropVocals(self, st)) {
            ok = %orig;
            DZLog("audio: engine #%lu: removed the vocals unit, retried start: %@", (unsigned long)st.serial,
                  ok ? @"OK (Sing unavailable this session)" : @"still failing");
        }
        // then all of Deezit's units, so a bad splice costs the effect, never the music
        if (!ok && !st.gaveUp && st.reverb.engine == self) {
            st.gaveUp = YES;
            if (unsplice(self, st)) {
                ok = %orig;
                DZLog("audio: engine #%lu: removed Deezit's units, retried start: %@", (unsigned long)st.serial,
                      ok ? @"OK, playing without the effect" : @"still failing (not Deezit's fault)");
            }
        }
    }
    logGraphIfChanged(self, @"start");
    return ok;
}

%end

%end

#pragma mark - public

void DZAudioInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        if (!DZPrefBool(kDZAudioHook)) {
            DZLog("audio: hook is OFF (kill switch in the debug panel), Deezer's audio is untouched");
            return;
        }
        sStates = [NSHashTable weakObjectsHashTable];
        %init(DZEngineHooks);
        sActive = DZAudioBackendAVAudioEngine;
        [[NSNotificationCenter defaultCenter] addObserverForName:DZPrefsChangedNotification object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) { applyParamsToAll(); }];
        DZLog("audio: AVAudioEngine hooks installed (connect:to:format:, prepare, startAndReturnError:)");
    });
}

DZAudioBackend DZAudioActiveBackend(void) { return sActive; }

NSString *DZAudioBackendDescription(void) {
    if (sActive != DZAudioBackendAVAudioEngine) {
        return DZPrefBool(kDZAudioHook) ? @"not installed" : @"off (kill switch in the debug panel)";
    }
    NSUInteger spliced;
    @synchronized (sLock) { spliced = sSplices; }
    return spliced ? @"AVAudioEngine, active" : @"AVAudioEngine, waiting for playback";
}

NSString *DZAudioStatusSummary(void) {
    @synchronized (sLock) {
        return [NSString stringWithFormat:@"backend: %@ · engines seen %lu · splices %lu · failures %lu%@",
                sActive == DZAudioBackendAVAudioEngine ? @"AVAudioEngine" : @"none",
                (unsigned long)sEnginesSeen, (unsigned long)sSplices, (unsigned long)sFailures,
                sLastError ? [@"\nlast error: " stringByAppendingString:sLastError] : @""];
    }
}
