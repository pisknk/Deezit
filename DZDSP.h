#pragma once
// Engine-agnostic DSP core: varispeed (pitch follows speed) + reverb.
// Pure C, realtime-safe after DZDSPCreate: no allocation, locks or ObjC in
// DZDSPProcess. Every audio backend (RemoteIO render wrap, AVPlayer tap,
// AVAudioEngine node) feeds this same core.

#include <stdbool.h>
#include <stdint.h>
#include "DZAudioParams.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DZDSP DZDSP;

// Pulls `frames` frames of the *source* (unprocessed) stream into `out`
// (non-interleaved float, one pointer per channel). Returns frames delivered.
// The varispeed stage calls this to read faster/slower than real time.
typedef uint32_t (*DZDSPPullFn)(void *ctx, float *const *out, uint32_t frames);

DZDSP *DZDSPCreate(double sampleRate, uint32_t channels, uint32_t maxFrames);
void DZDSPDestroy(DZDSP *dsp);
void DZDSPReset(DZDSP *dsp);

// Produces `frames` output frames into `out`, pulling roughly
// frames * params.speed source frames through `pull`.
// When params.enabled is false this is a straight pass-through pull.
void DZDSPRender(DZDSP *dsp, DZAudioParams params,
                 DZDSPPullFn pull, void *pullCtx,
                 float *const *out, uint32_t frames);

// In-place reverb only (for backends that cannot change the read rate,
// e.g. an MTAudioProcessingTap where speed is set via the player's rate).
void DZDSPProcessReverb(DZDSP *dsp, DZAudioParams params,
                        float *const *io, uint32_t frames);

#ifdef __cplusplus
}
#endif
