#import "DZVocalUnit.h"
#import <AudioToolbox/AudioToolbox.h>
#import "DZLog.h"
#include "DZVocals.h"
#include "DZAudioParams.h"
#include <stdlib.h>

// Everything the render block touches, in one C struct so the block never
// messages ObjC on the audio thread.
typedef struct {
    DZVocals dsp;
    AudioBufferList *pull;        // our input buffer (owned by _pullBuffer)
    AUAudioFrameCount maxFrames;
} DZVocalRender;

@interface DZVocalUnit : AUAudioUnit
@end

@implementation DZVocalUnit {
    AUAudioUnitBus *_inputBus, *_outputBus;
    AUAudioUnitBusArray *_inputBusses, *_outputBusses;
    AVAudioPCMBuffer *_pullBuffer;
    DZVocalRender *_render;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    if (!(self = [super initWithComponentDescription:desc options:options error:outError])) return nil;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    _inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    _outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:outError];
    if (!_inputBus || !_outputBus) return nil;
    _inputBus.maximumChannelCount = 2;
    _outputBus.maximumChannelCount = 2;
    _inputBusses = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeInput busses:@[_inputBus]];
    _outputBusses = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self busType:AUAudioUnitBusTypeOutput busses:@[_outputBus]];
    _render = calloc(1, sizeof(DZVocalRender));
    if (!_render) return nil;
    self.maximumFramesToRender = 4096;
    return self;
}

- (void)dealloc {
    free(_render);
}

- (AUAudioUnitBusArray *)inputBusses { return _inputBusses; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusses; }

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;
    AVAudioFormat *format = _inputBus.format;
    if (format.channelCount != 2 || format.commonFormat != AVAudioPCMFormatFloat32 || format.isInterleaved) {
        DZLog("vocals: unsupported format %@", format);
        if (outError) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioUnitErr_FormatNotSupported userInfo:nil];
        return NO;
    }
    _pullBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:self.maximumFramesToRender];
    _render->pull = _pullBuffer.mutableAudioBufferList;
    _render->maxFrames = self.maximumFramesToRender;
    DZVocalsSetup(&_render->dsp, format.sampleRate);
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    _render->pull = NULL;
    _pullBuffer = nil;
}

- (AUInternalRenderBlock)internalRenderBlock {
    DZVocalRender *r = _render;
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frames, NSInteger outputBus, AudioBufferList *out,
                              const AURenderEvent *events, AURenderPullInputBlock __unsafe_unretained pullInput) {
        // (the SDK declares pullInputBlock __unsafe_unretained; the literal must match under ARC)
        AudioBufferList *in = r->pull;
        if (!pullInput || !in) return kAudioUnitErr_NoConnection;
        if (frames > r->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
        if (in->mNumberBuffers < 2 || out->mNumberBuffers < 2) return kAudioUnitErr_FormatNotSupported;

        for (UInt32 i = 0; i < in->mNumberBuffers; i++) in->mBuffers[i].mDataByteSize = frames * sizeof(float);
        AudioUnitRenderActionFlags pullFlags = 0;
        AUAudioUnitStatus status = pullInput(&pullFlags, timestamp, frames, 0, in);
        if (status != noErr) return status;

        for (UInt32 i = 0; i < out->mNumberBuffers; i++) {
            if (!out->mBuffers[i].mData) out->mBuffers[i].mData = in->mBuffers[i].mData;   // process in place
            out->mBuffers[i].mDataByteSize = frames * sizeof(float);
        }
        DZVocalsProcess(&r->dsp, DZPrefsAudioParams().vocalCut,
                        in->mBuffers[0].mData, in->mBuffers[1].mData,
                        out->mBuffers[0].mData, out->mBuffers[1].mData, frames);
        return noErr;
    };
}

@end

AVAudioUnitEffect *DZVocalUnitCreate(void) {
    // 'dzvc' / 'Dzit': an effect only this process knows about
    AudioComponentDescription desc = { kAudioUnitType_Effect, 'dzvc', 'Dzit', 0, 0 };
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [AUAudioUnit registerSubclass:[DZVocalUnit class] asComponentDescription:desc name:@"Deezit: Vocals" version:1];
    });
    @try {
        AVAudioUnitEffect *effect = [[AVAudioUnitEffect alloc] initWithAudioComponentDescription:desc];
        if (!effect) DZLog("vocals: couldn't create the vocals unit");
        return effect;
    } @catch (NSException *ex) {
        DZLog("vocals: creating the vocals unit failed: %@", ex.reason);
        return nil;
    }
}
