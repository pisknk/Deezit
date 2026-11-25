#pragma once
#import <AVFoundation/AVFoundation.h>

// Probe for AutoMix (DZAutoMixProbe.x): how Deezer changes songs, and Apple's
// analysis of each track. Logs "automix:" lines; changes nothing.
void DZAutoMixProbeInstall(void);

// For the buffer probe: is a song change being watched now, and one buffer a
// player node schedules (`aheadBefore`: seconds already queued on that node,
// i.e. when this buffer will be heard).
BOOL DZAutoMixProbeWants(void);
void DZAutoMixProbeBuffer(NSUInteger serial, AVAudioPCMBuffer *buffer, double aheadBefore);
