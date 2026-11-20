#pragma once
// Plain C (shared by the ObjC tweak and the C DSP core).
#include <stdbool.h>

// Realtime-safe snapshot of the audio settings, read on the render thread:
// no locks, no ObjC, no allocation.
typedef struct {
    bool  enabled;
    float speed;       // 0.50 ... 1.50, pitch follows speed
    float reverbMix;   // 0 ... 1
    float reverbRoom;  // 0 ... 1
    float reverbDamp;  // 0 ... 1
    float vocalCut;    // 0 = vocals untouched ... 1 = all vocals removed (Sing)
                       // (independent of `enabled`; 0 before prefs load)
    float backingKeep; // 0 = backing vocals go with the lead ... 1 = only the
                       // centred lead is removed, side-panned backing vocals stay
} DZAudioParams;

#ifdef __cplusplus
extern "C" {
#endif
DZAudioParams DZPrefsAudioParams(void);
#ifdef __cplusplus
}
#endif
