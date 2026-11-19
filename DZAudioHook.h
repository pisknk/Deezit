#pragma once
#import <Foundation/Foundation.h>

// Where the effect is spliced into Deezer's audio. Which one v1 uses is decided
// by the IPA analysis (docs/ANALYSIS.md) - only one is active at a time.
typedef NS_ENUM(NSInteger, DZAudioBackend) {
    DZAudioBackendNone = 0,
    // Wrap the render callback of Deezer's RemoteIO / AUGraph output unit
    // (via fishhook on AudioUnitSetProperty). Pulls speed*N source frames per
    // N output frames -> true varispeed at the output, works for any decoder.
    DZAudioBackendRemoteIO,
    // AVPlayer: rate + AVAudioTimePitchAlgorithmVarispeed for speed,
    // MTAudioProcessingTap on the item's audioMix for reverb.
    DZAudioBackendAVPlayer,
    // AVAudioEngine: AVAudioUnitVarispeed + DSP node inserted before the
    // main mixer when Deezer builds its graph.
    DZAudioBackendAVAudioEngine,
    // AVSampleBufferAudioRenderer: synchronizer rate + process buffers
    // before -enqueueSampleBuffer:.
    DZAudioBackendSampleBufferRenderer,
};

void DZAudioInstall(void);
DZAudioBackend DZAudioActiveBackend(void);
NSString *DZAudioBackendDescription(void);
