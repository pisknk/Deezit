// Host-side checks of AutoMix's plain-C DSP (DZTimeStretch.c, DZTransitionFX.c),
// run by CI before the tweak is built:
//   clang -O2 -Wall -o dsp_test tests/dsp_test.c DZTimeStretch.c DZTransitionFX.c -lm && ./dsp_test
// Buffers are fed the way Deezer schedules them: 3675 frames (83 ms) at 44.1 kHz.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../DZTimeStretch.h"
#include "../DZTransitionFX.h"

#define SR 44100.0
#define BUF 3675

static int failures;

static void check(int ok, const char *what) {
    printf("%s  %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) failures++;
}

typedef struct {
    float *ch[2];
    long len, cap;
} Out;

static void outAppend(Out *o, float *const *src, int n) {
    if (o->len + n > o->cap) {
        o->cap = (o->len + n) * 2;
        for (int c = 0; c < 2; c++) o->ch[c] = realloc(o->ch[c], sizeof(float) * (size_t)o->cap);
    }
    for (int c = 0; c < 2; c++) memcpy(o->ch[c] + o->len, src[c], sizeof(float) * (size_t)n);
    o->len += n;
}

// Runs a stereo signal through the stretcher buffer by buffer. rate(k) per
// buffer; finishAt: buffer index that finishes (later ones pass through), -1 never.
static Out run(float *const *sig, long len, double (*rate)(int), int finishAt, int *capExceeded, int *minOut) {
    Out o = { { NULL, NULL }, 0, 0 };
    DZStretch *s = DZStretchCreate(2, SR, 0);
    int done = 0;
    *capExceeded = 0;
    *minOut = 1 << 30;
    for (long i = 0, k = 0; i < len; i += BUF, k++) {
        int n = (int)(len - i < BUF ? len - i : BUF);
        const float *in[2] = { sig[0] + i, sig[1] + i };
        if (done) {
            outAppend(&o, (float *const *)in, n);
            continue;
        }
        double r = rate((int)k);
        int cap = DZStretchCapacity(s, n, r);
        float *buf[2] = { malloc(sizeof(float) * (size_t)cap), malloc(sizeof(float) * (size_t)cap) };
        int w;
        if (k == finishAt) {
            w = DZStretchFinish(s, in, n, 1, buf, 1, cap);
            done = 1;
        } else {
            w = DZStretchProcess(s, in, n, 1, r, buf, 1, cap);
        }
        if (w > cap) *capExceeded = 1;
        if (w < *minOut) *minOut = w;
        outAppend(&o, buf, w);
        free(buf[0]);
        free(buf[1]);
    }
    DZStretchDestroy(s);
    return o;
}

static double rate1(int k) { (void)k; return 1.0; }
static double rate095(int k) { (void)k; return 0.95; }
static double rateSlow(int k) { (void)k; return 1 / 1.05; }

static float *alloc(long n) { return calloc((size_t)n, sizeof(float)); }

int main(void) {
    long len = (long)(SR * 12);
    float *sine[2] = { alloc(len), alloc(len) };
    for (long i = 0; i < len; i++) {
        sine[0][i] = (float)(0.5 * sin(2 * M_PI * 440 * i / SR));
        sine[1][i] = (float)(0.3 * sin(2 * M_PI * 220 * i / SR));
    }
    int capEx, minOut;

    // 1. rate 1, then finish: the output is the input itself
    Out o = run(sine, len, rate1, 40, &capEx, &minOut);
    double maxErr = 0;
    for (long i = 0; i < len && i < o.len; i++) {
        double e = fabs(o.ch[0][i] - sine[0][i]) + fabs(o.ch[1][i] - sine[1][i]);
        if (e > maxErr) maxErr = e;
    }
    printf("     rate 1: in %ld out %ld, max error %.2e, smallest buffer %d\n", len, o.len, maxErr, minOut);
    check(o.len == len, "rate 1 + finish keeps the length");
    check(maxErr < 1e-5, "rate 1 + finish gives the input back");
    check(!capEx, "never more than DZStretchCapacity");
    check(minOut > 0, "every buffer has output");

    // 2. a sine slowed to 95 %: no clicks, steady level, length / 0.95
    o = run(sine, len, rate095, 60, &capEx, &minOut);
    double w = 2 * M_PI * 440 / SR, maxRes = 0, minAmp = 1, maxAmp = 0;
    for (long i = 2; i < o.len; i++) {
        double r = fabs(o.ch[0][i] - 2 * cos(w) * o.ch[0][i - 1] + o.ch[0][i - 2]);
        if (r > maxRes) maxRes = r;
    }
    for (long i = 0; i + 2000 < o.len; i += 2000) {
        double m = 0;
        for (long j = i; j < i + 2000; j++) m = fmax(m, fabs(o.ch[0][j]));
        minAmp = fmin(minAmp, m);
        maxAmp = fmax(maxAmp, m);
    }
    long want = (long)(60 * BUF / 0.95) + (len - 60 * BUF);
    printf("     sine at 0.95: out %ld (about %ld), max residual %.4f, level %.3f-%.3f\n", o.len, want, maxRes, minAmp, maxAmp);
    check(labs(o.len - want) < 2048, "slowed length matches the rate");
    check(maxRes < 0.01, "slowed sine stays smooth");
    check(minAmp > 0.49 && maxAmp < 0.51, "slowed sine keeps its level");
    check(!capEx && minOut > 0, "slowed: within capacity, output every buffer");

    // 3. a 120 bpm click track slowed by 5 %: clicks 0.525 s apart
    long clen = (long)(SR * 20);
    float *clicks[2] = { alloc(clen), alloc(clen) };
    for (double b = 0; b < 20; b += 0.5) {
        long n0 = (long)(b * SR);
        for (int i = 0; i < 400 && n0 + i < clen; i++)
            clicks[0][n0 + i] = clicks[1][n0 + i] = (float)(exp(-i / 60.0) * sin(2 * M_PI * 1000 * i / SR));
    }
    o = run(clicks, clen, rateSlow, -1, &capEx, &minOut);
    long onsets[64];
    int no = 0;
    for (long i = 0; i < o.len && no < 64;) {
        if (o.ch[0][i] * o.ch[0][i] > 0.05) {
            onsets[no++] = i;
            i += (long)(0.3 * SR);
        } else {
            i++;
        }
    }
    double sum = 0, mn = 1e9, mx = 0;
    for (int i = 1; i < no; i++) {
        double d = (onsets[i] - onsets[i - 1]) / SR;
        sum += d;
        mn = fmin(mn, d);
        mx = fmax(mx, d);
    }
    double mean = no > 1 ? sum / (no - 1) : 0;
    printf("     clicks at 1/1.05: %d clicks, %.4f s apart on average (want 0.5250), %.4f-%.4f\n", no, mean, mn, mx);
    check(no >= 35, "clicks survive the stretch");
    check(fabs(mean - 0.525) < 0.002, "clicks follow the new tempo");
    check(mn > 0.515 && mx < 0.535, "clicks stay within 10 ms of the beat");

    // 4. transition effects
    DZFXPlan p;
    memset(&p, 0, sizeof p);
    p.style = DZFXBassSwap;
    p.durationA = 200;
    p.beatA = 0.5;
    p.start = 180;
    p.swap = 188;
    p.swapB = 8;
    p.length = 20;
    p.tailA = 4;
    p.ownGainA = 1;
    DZFXState *st = DZFXStateCreate(SR);
    float *a[2] = { alloc(BUF), alloc(BUF) };
    double peakAfter = 0, peakBefore = 0;
    int finite = 1;
    for (double t = 178; t < 196; t += BUF / SR) {
        for (int i = 0; i < BUF; i++) a[0][i] = a[1][i] = (float)(0.5 * sin(2 * M_PI * 1000 * (t + i / SR)));
        DZFXProcess(st, &p, DZFXRoleA, a, 2, BUF, 1, t);
        for (int i = 0; i < BUF; i++) {
            if (!isfinite(a[0][i])) finite = 0;
            if (t < p.swap - 1) peakBefore = fmax(peakBefore, fabs(a[0][i]));
            if (t > p.swap + p.tailA + 0.1) peakAfter = fmax(peakAfter, fabs(a[0][i]));
        }
    }
    DZFXStateDestroy(st);
    printf("     bass swap A: peak %.3f before the swap, %.5f after its tail\n", peakBefore, peakAfter);
    check(finite, "bass swap A stays finite");
    check(peakBefore > 0.45, "bass swap A untouched before the swap (1 kHz)");
    check(peakAfter < 1e-4, "bass swap A silent after its tail");

    DZFXStyle styles[3] = { DZFXBassSwap, DZFXEchoOut, DZFXFilterFade };
    for (int si = 0; si < 3; si++) {
        for (int role = 0; role < 2; role++) {
            p.style = styles[si];
            st = DZFXStateCreate(SR);
            int ok = 1;
            double t0 = role == 0 ? 178 : 0;
            for (double t = t0; t < t0 + 25; t += BUF / SR) {
                for (int i = 0; i < BUF; i++) a[0][i] = a[1][i] = (float)((rand() / (double)RAND_MAX - 0.5));
                DZFXProcess(st, &p, (DZFXRole)role, a, 2, BUF, 1, t);
                for (int i = 0; i < BUF; i++)
                    if (!isfinite(a[0][i]) || fabs(a[0][i]) > 4) ok = 0;
            }
            DZFXStateDestroy(st);
            char what[64];
            snprintf(what, sizeof what, "style %d role %c stays finite and bounded", (int)styles[si], role ? 'B' : 'A');
            check(ok, what);
        }
    }

    printf("%s\n", failures ? "DSP checks FAILED" : "DSP checks passed");
    return failures ? 1 : 0;
}
