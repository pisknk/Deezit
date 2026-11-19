#pragma once
#import <Foundation/Foundation.h>

// Where the effect is spliced into Deezer's audio. docs/ANALYSIS.md picked
// AVAudioEngine for Deezer 11.27.0; the other cases stay as documentation of
// the alternatives (and for other apps / future Deezer versions).
typedef NS_ENUM(NSInteger, DZAudioBackend) {
    DZAudioBackendNone = 0,
    // Wrap the render callback of a RemoteIO / AUGraph output unit.
    DZAudioBackendRemoteIO,
    // AVPlayer: rate + Varispeed pitch algorithm, MTAudioProcessingTap reverb.
    DZAudioBackendAVPlayer,
    // AVAudioEngine: AVAudioUnitVarispeed + Apple Reverb2 spliced between
    // Deezer's last node (its main mixer) and the engine's output node.
    DZAudioBackendAVAudioEngine,
    // AVSampleBufferAudioRenderer: synchronizer rate + buffer processing.
    DZAudioBackendSampleBufferRenderer,
};

void DZAudioInstall(void);
DZAudioBackend DZAudioActiveBackend(void);
// One line for the settings footer.
NSString *DZAudioBackendDescription(void);
// A few lines for the debug panel: engines seen / spliced, last error.
NSString *DZAudioStatusSummary(void);
