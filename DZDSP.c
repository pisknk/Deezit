#include "DZDSP.h"
#include <stdlib.h>
#include <string.h>

// v1 SKELETON: pass-through. The varispeed resampler and the reverb network
// land once the analysis has picked the backend (see docs/ANALYSIS.md).

struct DZDSP {
    double sampleRate;
    uint32_t channels;
    uint32_t maxFrames;
};

DZDSP *DZDSPCreate(double sampleRate, uint32_t channels, uint32_t maxFrames) {
    DZDSP *d = calloc(1, sizeof(DZDSP));
    if (!d) return NULL;
    d->sampleRate = sampleRate;
    d->channels = channels;
    d->maxFrames = maxFrames;
    return d;
}

void DZDSPDestroy(DZDSP *dsp) { free(dsp); }

void DZDSPReset(DZDSP *dsp) { (void)dsp; }

void DZDSPRender(DZDSP *dsp, DZAudioParams params,
                 DZDSPPullFn pull, void *pullCtx,
                 float *const *out, uint32_t frames) {
    (void)params;
    uint32_t got = pull(pullCtx, out, frames);
    if (got < frames) {
        for (uint32_t c = 0; c < dsp->channels; c++) {
            memset(out[c] + got, 0, (frames - got) * sizeof(float));
        }
    }
    // TODO(v1): resample by params.speed, then DZDSPProcessReverb.
}

void DZDSPProcessReverb(DZDSP *dsp, DZAudioParams params,
                        float *const *io, uint32_t frames) {
    (void)dsp; (void)params; (void)io; (void)frames;
    // TODO(v1): comb/all-pass reverb, wet/dry by params.reverbMix.
}
