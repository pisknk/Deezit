#pragma once
#import <Foundation/Foundation.h>

// Logs how Deezer schedules audio on its AVAudioPlayerNodes (see DZBufferProbe.x).
void DZBufferProbeInstall(void);
// Latest summary line, for the debug panel.
NSString *DZBufferProbeStatus(void);
