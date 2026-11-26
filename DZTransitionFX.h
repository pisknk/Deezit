#pragma once
// AutoMix transition effects (plain C, no allocation while processing).
//
// Applied to the buffers Deezer schedules on the outgoing (A) and incoming (B)
// song's player node, about 3 s before they're heard, by song position: A's
// effects by A's time, B's by B's time. B fades in with Deezer's (shortened)
// fade-in; A's level is shaped here when Deezer's own fade-out is held off
// (ownGainA), else by Deezer.

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DZFXNone = 0,
    DZFXBassSwap,     // B comes in without bass; on the downbeat A's bass goes and B's comes in
    DZFXEchoOut,      // A's last beats echo (tempo-synced) and A drops out on the downbeat B lands on
    DZFXFilterFade,   // A closes into a low-pass, B opens up from a high-pass
} DZFXStyle;

typedef enum { DZFXRoleA = 0, DZFXRoleB = 1 } DZFXRole;

typedef struct {
    DZFXStyle style;
    double start;      // A's time (s) at which B starts
    double swap;       // A's time (s) of the swap / echo point (a bar line)
    double swapB;      // B's time (s) of that same moment
    double length;     // the overlap (s)
    double durationA;  // A's length (s)
    double beatA;      // one beat of A (s)
    double tailA;      // bass swap: A fades out over this long after the swap (s)
    int ownGainA;      // Deezer's fade-out of A is held off: A's level is shaped here
} DZFXPlan;

typedef struct DZFXState DZFXState;

DZFXState *DZFXStateCreate(double sampleRate);
void DZFXStateDestroy(DZFXState *s);

// One buffer (non-interleaved float channels, 1 or 2) starting at song time t0.
void DZFXProcess(DZFXState *s, const DZFXPlan *p, DZFXRole role, float *const *channels, int channelCount,
                 int frames, int stride, double t0);

#ifdef __cplusplus
}
#endif
