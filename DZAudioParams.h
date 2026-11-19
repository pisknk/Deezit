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
} DZAudioParams;

#ifdef __cplusplus
extern "C" {
#endif
DZAudioParams DZPrefsAudioParams(void);
#ifdef __cplusplus
}
#endif
