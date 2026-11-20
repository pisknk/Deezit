#pragma once
// Vocal reduction ("Sing", DSP version). Plain C, realtime-safe: no
// allocation, locks or ObjC in DZVocalsProcess.
//
// Lead vocals are usually mixed dead centre, so they live in the mid signal
// M = (L+R)/2 and not in the side signal S = (L-R)/2. Removing the voice band
// (~120 Hz - 8 kHz) of M, scaled by `cut`, takes the voice down while bass,
// kick and cymbals (outside the band) and everything panned off-centre (in S)
// stay. Works best on studio mixes with a centred, dry lead vocal; centred
// instruments in the same band (snare, some synths) are reduced too.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double b0, b1, b2, a1, a2;   // normalised coefficients
    double z1, z2;               // transposed direct form II state
} DZBiquad;

typedef struct {
    DZBiquad highpass, lowpass;  // the voice band of the mid signal
    float cut;                   // smoothed amount removed, 0 ... 1
} DZVocals;

void DZVocalsSetup(DZVocals *v, double sampleRate);

// cut: 0 = untouched ... 1 = voice band of the centre removed. The value is
// smoothed per sample (~10 ms), so it can jump between calls without clicks.
// in and out may be the same buffers.
void DZVocalsProcess(DZVocals *v, float cut, const float *inL, const float *inR,
                     float *outL, float *outR, uint32_t frames);

#ifdef __cplusplus
}
#endif
