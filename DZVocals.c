#include "DZVocals.h"
#include <math.h>
#include <string.h>

static const double kDZVoiceLow = 120.0;    // Hz: below this, keep (bass, kick)
static const double kDZVoiceHigh = 8000.0;  // Hz: above this, keep (cymbals, air)
static const double kDZQ = 0.7071;          // Butterworth

// RBJ audio-EQ-cookbook biquads.
static void designBiquad(DZBiquad *f, double sampleRate, double freq, int highpass) {
    double w0 = 2.0 * M_PI * freq / sampleRate;
    double cosw = cos(w0), alpha = sin(w0) / (2.0 * kDZQ);
    double a0 = 1.0 + alpha;
    double b0, b1, b2;
    if (highpass) { b0 = (1.0 + cosw) / 2.0; b1 = -(1.0 + cosw); b2 = (1.0 + cosw) / 2.0; }
    else          { b0 = (1.0 - cosw) / 2.0; b1 = 1.0 - cosw;    b2 = (1.0 - cosw) / 2.0; }
    f->b0 = b0 / a0;
    f->b1 = b1 / a0;
    f->b2 = b2 / a0;
    f->a1 = -2.0 * cosw / a0;
    f->a2 = (1.0 - alpha) / a0;
    f->z1 = f->z2 = 0;
}

static inline double runBiquad(DZBiquad *f, double x) {
    double y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}

void DZVocalsSetup(DZVocals *v, double sampleRate) {
    if (sampleRate <= 0) sampleRate = 44100;
    double high = fmin(kDZVoiceHigh, sampleRate * 0.45);
    designBiquad(&v->highpass, sampleRate, kDZVoiceLow, 1);
    designBiquad(&v->lowpass, sampleRate, high, 0);
    v->cut = 0;
}

void DZVocalsProcess(DZVocals *v, float cut, const float *inL, const float *inR,
                     float *outL, float *outR, uint32_t frames) {
    if (cut < 0) cut = 0;
    if (cut > 1) cut = 1;
    float g = v->cut;
    // fully off and settled: plain pass-through; the filters restart from
    // silence next time (the cut ramps up from 0, so that's inaudible)
    if (cut == 0 && g < 1e-4f) {
        v->cut = 0;
        v->highpass.z1 = v->highpass.z2 = v->lowpass.z1 = v->lowpass.z2 = 0;
        if (outL != inL) memcpy(outL, inL, frames * sizeof(float));
        if (outR != inR) memcpy(outR, inR, frames * sizeof(float));
        return;
    }
    for (uint32_t i = 0; i < frames; i++) {
        g += (cut - g) * 0.002f;                 // ~10 ms at 44.1 kHz
        float l = inL[i], r = inR[i];
        float mid = 0.5f * (l + r), side = 0.5f * (l - r);
        double band = runBiquad(&v->lowpass, runBiquad(&v->highpass, mid));
        float m = mid - g * (float)band;
        outL[i] = m + side;
        outR[i] = m - side;
    }
    v->cut = g;
}
