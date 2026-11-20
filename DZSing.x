// Hooks for "Sing" (AI vocal removal, DZSeparator.m): Deezer's buffers are
// taken at the point it schedules them on its AVAudioPlayerNodes.
//
// Installed after DZBufferProbe.x, so this hook runs first; buffers Deezit
// schedules itself (DZSingInside > 0) go straight through to the probe and
// AVFoundation.

#import <AVFoundation/AVFoundation.h>
#import "DZSeparator.h"
#import "DZPrefs.h"
#import "DZLog.h"

%group DZSingHooks

%hook AVAudioPlayerNode

// Deezer schedules with atTime nil / options 0; anything else is left alone.
- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options completionHandler:(AVAudioNodeCompletionHandler)handler {
    if (DZSingInside || !buffer || when || options) {
        %orig;
        return;
    }
    if (!DZSingSchedule(self, buffer, handler)) %orig;
}

- (void)stop {
    DZSingStop(self);
    %orig;
}

%end

%end

void DZSingInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!DZPrefBool(kDZAudioHook)) return;   // the debug panel's kill switch covers Sing too
        %init(DZSingHooks);
        DZLog("sing: hooks installed (AI vocal removal when the model is downloaded and Vocals < 100%%)");
    });
}
