#include "DZTransitionFX.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// RBJ-cookbook biquads (transposed direct form II), coefficients updated
// every kBlock frames as the cutoff sweeps, and a feedback echo whose repeats
// darken through a one-pole low-pass.

enum { kBlock = 32, kMaxCh = 2 };
static const double kMaxDelay = 1.6;   // s

typedef struct { double b0, b1, b2, a1, a2; } Coefs;
typedef struct { double z1, z2; } BiquadState;

struct DZFXState {
    double sr;
    BiquadState hp[kMaxCh], lp[kMaxCh];
    float *delay[kMaxCh];
    int delayCap, delayLen, writeIdx;
    float fbLow[kMaxCh];
    float dryGain;
    float levelA;          // A's own fade (ownGainA), last block's value
};

DZFXState *DZFXStateCreate(double sampleRate) {
    DZFXState *s = calloc(1, sizeof(DZFXState));
    if (!s) return NULL;
    s->sr = sampleRate > 1000 ? sampleRate : 44100;
    s->delayCap = (int)(kMaxDelay * s->sr) + 1;
    for (int c = 0; c < kMaxCh; c++) s->delay[c] = calloc((size_t)s->delayCap, sizeof(float));
    s->dryGain = 1;
    s->levelA = 1;
    return s;
}

void DZFXStateDestroy(DZFXState *s) {
    if (!s) return;
    for (int c = 0; c < kMaxCh; c++) free(s->delay[c]);
    free(s);
}

static Coefs highpass(double fc, double sr) {
    double w0 = 2 * M_PI * fc / sr, cw = cos(w0), alpha = sin(w0) / (2 * 0.7071);
    double a0 = 1 + alpha;
    Coefs k = { (1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0 };
    return k;
}

static Coefs lowpass(double fc, double sr) {
    double w0 = 2 * M_PI * fc / sr, cw = cos(w0), alpha = sin(w0) / (2 * 0.7071);
    double a0 = 1 + alpha;
    Coefs k = { (1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0 };
    return k;
}

static void runBiquad(Coefs k, BiquadState *st, float *x, int n, int stride) {
    double z1 = st->z1, z2 = st->z2;
    for (int i = 0; i < n; i++) {
        double in = x[(long)i * stride];
        double out = k.b0 * in + z1;
        z1 = k.b1 * in - k.a1 * out + z2;
        z2 = k.b2 * in - k.a2 * out;
        x[(long)i * stride] = (float)out;
    }
    st->z1 = z1;
    st->z2 = z2;
}

static double clamp01(double x) { return x < 0 ? 0 : (x > 1 ? 1 : x); }

// exponential sweep from f0 to f1 as x goes 0 -> 1
static double sweep(double f0, double f1, double x) { return f0 * pow(f1 / f0, clamp01(x)); }

// A's level at time t when Deezer's fade-out is held off (1 = untouched)
static double levelA(const DZFXPlan *p, double t) {
    if (!p->ownGainA) return 1;
    switch (p->style) {
        case DZFXBassSwap: {
            // full until the swap, gone over the tail (A plays on silently to its end)
            if (t < p->swap) return 1;
            double tail = p->tailA > 0.2 ? p->tailA : 2;
            double x = clamp01((t - p->swap) / tail);
            return 0.5 * (1 + cos(M_PI * x));
        }
        case DZFXFilterFade: {
            double span = p->durationA - p->start;
            return span > 0.5 ? cos(0.5 * M_PI * clamp01((t - p->start) / span)) : 1;
        }
        default:
            return 1;   // echo out: A's dry sound stops on the downbeat by itself
    }
}

void DZFXProcess(DZFXState *s, const DZFXPlan *p, DZFXRole role, float *const *ch, int channelCount,
                 int frames, int stride, double t0) {
    if (!s || !p || p->style == DZFXNone || frames <= 0 || channelCount <= 0) return;
    if (channelCount > kMaxCh) channelCount = kMaxCh;
    if (stride < 1) stride = 1;
    const double sr = s->sr, nyq = 0.45 * sr;
    const double beat = p->beatA > 0.2 && p->beatA < 2 ? p->beatA : 0.5;

    if (p->style == DZFXEchoOut && role == DZFXRoleA) {
        int want = (int)lround(0.75 * beat * sr);
        if (want < 1) want = 1;
        if (want >= s->delayCap) want = s->delayCap - 1;
        if (want != s->delayLen) {
            s->delayLen = want;
            s->writeIdx = 0;
            for (int c = 0; c < kMaxCh; c++) memset(s->delay[c], 0, sizeof(float) * (size_t)s->delayCap);
        }
    }

    for (int i0 = 0; i0 < frames; i0 += kBlock) {
        int n = frames - i0 < kBlock ? frames - i0 : kBlock;
        double t = t0 + (i0 + n * 0.5) / sr;
        double hp = 0, lp = 0;    // 0 = filter not in the path

        switch (p->style) {
            case DZFXBassSwap:
                if (role == DZFXRoleA) {
                    // over the last beat before the swap the bass is pulled out
                    hp = sweep(12, 320, (t - (p->swap - beat)) / beat);
                } else {
                    // no bass until the swap, then it drops in within ~60 ms
                    hp = t < p->swapB - 0.03 ? 320 : sweep(320, 12, (t - (p->swapB - 0.03)) / 0.06);
                }
                break;
            case DZFXFilterFade:
                if (role == DZFXRoleA) {
                    double span = p->durationA - p->start;
                    lp = sweep(nyq, 320, span > 0.5 ? (t - p->start) / span : 1);
                } else {
                    hp = sweep(700, 12, (t) / (p->length > 1 ? p->length * 0.8 : 1));
                }
                break;
            default:
                break;
        }

        for (int c = 0; c < channelCount; c++) {
            float *x = ch[c] + (long)i0 * stride;
            if (hp > 0) runBiquad(highpass(hp, sr), &s->hp[c], x, n, stride);
            if (lp > 0) runBiquad(lowpass(lp < nyq ? lp : nyq, sr), &s->lp[c], x, n, stride);
        }

        if (role == DZFXRoleA && p->ownGainA) {
            // ramped across the block from the last block's level
            float g0 = s->levelA, g1 = (float)levelA(p, t0 + (double)(i0 + n) / sr);
            if (g0 != 1.0f || g1 != 1.0f) {
                for (int c = 0; c < channelCount; c++) {
                    float *x = ch[c] + (long)i0 * stride;
                    for (int i = 0; i < n; i++) x[(long)i * stride] *= g0 + (g1 - g0) * (float)(i + 1) / (float)n;
                }
            }
            s->levelA = g1;
        }

        if (p->style == DZFXEchoOut && role == DZFXRoleA && s->delayLen > 0) {
            // the echo takes in the last two beats before the drop-out, and is
            // heard from one beat before it; A's own sound stops on the downbeat
            double feedFrom = p->swap - 2 * beat;
            float targetDry = t < p->swap ? 1.0f : 0.0f;
            float wet = t >= p->swap - beat ? 0.7f : 0.0f;
            int dl = s->delayLen, cap = s->delayCap;
            float dry0 = s->dryGain;
            float step = (targetDry - dry0) / (float)(0.015 * sr);   // 15 ms ramp
            int w = s->writeIdx;
            for (int i = 0; i < n; i++) {
                double ti = t0 + (i0 + i) / sr;
                float dry = s->dryGain;
                if (step != 0) {
                    dry += step;
                    if ((step > 0 && dry > targetDry) || (step < 0 && dry < targetDry)) dry = targetDry;
                    s->dryGain = dry;
                }
                int r = w - dl;
                if (r < 0) r += cap;
                for (int c = 0; c < channelCount; c++) {
                    float *x = ch[c] + (long)(i0 + i) * stride;
                    float in = *x;
                    float echoed = s->delay[c][r];
                    // darker repeats
                    s->fbLow[c] += 0.45f * (echoed - s->fbLow[c]);
                    float feed = (ti >= feedFrom && ti < p->swap) ? in : 0.0f;
                    s->delay[c][w] = feed + 0.55f * s->fbLow[c];
                    *x = in * dry + echoed * wet;
                }
                if (++w >= cap) w = 0;
            }
            s->writeIdx = w;
        }
    }
}
