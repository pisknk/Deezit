#import "DZAudioHook.h"
#import "DZPrefs.h"
#import "DZLog.h"

// Set from the analysis. Until then nothing in Deezer's audio path is touched,
// so the skeleton is safe to inject: it only adds the settings page.
static const DZAudioBackend kDZChosenBackend = DZAudioBackendNone;

static DZAudioBackend sActive = DZAudioBackendNone;

void DZAudioInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        switch (kDZChosenBackend) {
            case DZAudioBackendNone:
                DZLog("audio: no backend selected yet (pending IPA analysis)");
                break;
            case DZAudioBackendRemoteIO:
            case DZAudioBackendAVPlayer:
            case DZAudioBackendAVAudioEngine:
            case DZAudioBackendSampleBufferRenderer:
                // TODO(v1): install the backend picked in docs/ANALYSIS.md.
                DZLog("audio: backend %ld not implemented yet", (long)kDZChosenBackend);
                break;
        }
        sActive = DZAudioBackendNone;
    });
}

DZAudioBackend DZAudioActiveBackend(void) { return sActive; }

NSString *DZAudioBackendDescription(void) {
    switch (sActive) {
        case DZAudioBackendNone: return @"not hooked yet (pending analysis)";
        case DZAudioBackendRemoteIO: return @"RemoteIO render callback";
        case DZAudioBackendAVPlayer: return @"AVPlayer rate + audio tap";
        case DZAudioBackendAVAudioEngine: return @"AVAudioEngine graph";
        case DZAudioBackendSampleBufferRenderer: return @"AVSampleBufferAudioRenderer";
    }
    return @"unknown";
}
