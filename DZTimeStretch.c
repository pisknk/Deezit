#include "DZTimeStretch.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// WSOLA: frames of kN input frames, Hann-windowed, overlap-added every kHs
// output frames. Frame k's ideal source is pos_k (pos advances kHs * rate per
// frame); its real source is moved by up to ±kDelta to where it continues the
// previous frame's source best, so the waveforms line up and nothing phases.
// A periodic Hann window at 50 % overlap sums to exactly 1, so wherever two
// frames come from consecutive input the output is the input itself.

enum {
    kN = 2048,
    kHs = kN / 2,
    kDelta = 512,
    kDec = 4,
    kL = 1024,           // compared length
    kMaxCh = 2,
};

struct DZStretch {
    int ch;
    double sr;
    float *in[kMaxCh];
    long cap;            // frames allocated per channel
    long base;           // absolute input frame of in[c][0]
    long len;            // frames held from base
    double pos;          // ideal source of the next frame (absolute input frame)
    long prevSrc;        // source of the last frame written
    int started;
    float acc[kMaxCh][kN];
    float win[kN];
    float ref[kL / kDec];
    float cand[(2 * kDelta + kL) / kDec];
};

DZStretch *DZStretchCreate(int channels, double sampleRate, double skipFrames) {
    if (channels < 1 || channels > kMaxCh) return NULL;
    DZStretch *s = calloc(1, sizeof(DZStretch));
    if (!s) return NULL;
    s->ch = channels;
    s->sr = sampleRate > 1000 ? sampleRate : 44100;
    s->cap = 1 << 16;
    for (int c = 0; c < channels; c++) {
        s->in[c] = calloc((size_t)s->cap, sizeof(float));
        if (!s->in[c]) {
            DZStretchDestroy(s);
            return NULL;
        }
    }
    for (int i = 0; i < kN; i++) s->win[i] = (float)(0.5 - 0.5 * cos(2 * M_PI * i / kN));
    s->pos = skipFrames > 0 ? skipFrames : 0;
    return s;
}

void DZStretchDestroy(DZStretch *s) {
    if (!s) return;
    for (int c = 0; c < kMaxCh; c++) free(s->in[c]);
    free(s);
}

static long frameEnd(const DZStretch *s) { return s->base + s->len; }

static int append(DZStretch *s, const float *const *in, int frames, int stride) {
    // drop what no frame will read again
    long keep = s->started ? s->prevSrc + kHs : (long)floor(s->pos);
    long lo = lround(s->pos) - kDelta - 1;
    if (lo < keep) keep = lo;
    if (keep > frameEnd(s)) keep = frameEnd(s);
    if (keep > s->base) {
        long drop = keep - s->base;
        for (int c = 0; c < s->ch; c++) memmove(s->in[c], s->in[c] + drop, sizeof(float) * (size_t)(s->len - drop));
        s->base += drop;
        s->len -= drop;
    }
    if (frames <= 0) return 1;
    if (s->len + frames > s->cap) {
        long cap = (s->len + frames) * 2;
        for (int c = 0; c < s->ch; c++) {
            float *p = realloc(s->in[c], sizeof(float) * (size_t)cap);
            if (!p) return 0;
            s->in[c] = p;
        }
        s->cap = cap;
    }
    if (stride < 1) stride = 1;
    for (int c = 0; c < s->ch; c++) {
        float *dst = s->in[c] + s->len;
        const float *src = in[c];
        if (stride == 1) memcpy(dst, src, sizeof(float) * (size_t)frames);
        else for (int i = 0; i < frames; i++) dst[i] = src[(long)i * stride];
    }
    s->len += frames;
    return 1;
}

static float mono(const DZStretch *s, long abs) {
    long o = abs - s->base;
    float v = s->in[0][o];
    if (s->ch > 1) v += s->in[1][o];
    return v;
}

// The source near `center` that continues the last frame best.
static long bestSource(DZStretch *s, long center) {
    const long natural = s->prevSrc + kHs, end = frameEnd(s);
    const int nr = kL / kDec;
    long lo = center - kDelta;
    if (lo < s->base) lo = s->base;
    int nc = (2 * kDelta + kL) / kDec;
    if (lo + (long)nc * kDec > end) nc = (int)((end - lo) / kDec);
    int lags = nc - nr + 1;
    if (lags < 1 || natural + kL > end) return center < s->base ? s->base : center;

    for (int j = 0; j < nr; j++) {
        float v = 0;
        for (int k = 0; k < kDec; k++) v += mono(s, natural + (long)j * kDec + k);
        s->ref[j] = v;
    }
    for (int j = 0; j < nc; j++) {
        float v = 0;
        for (int k = 0; k < kDec; k++) v += mono(s, lo + (long)j * kDec + k);
        s->cand[j] = v;
    }
    double energy = 0;
    for (int j = 0; j < nr; j++) energy += (double)s->cand[j] * s->cand[j];
    int best = -1;
    double bestScore = -INFINITY;
    for (int d = 0; d < lags; d++) {
        if (d > 0) {
            energy += (double)s->cand[d + nr - 1] * s->cand[d + nr - 1] - (double)s->cand[d - 1] * s->cand[d - 1];
            if (energy < 0) energy = 0;
        }
        double dot = 0;
        for (int j = 0; j < nr; j++) dot += (double)s->ref[j] * s->cand[d + j];
        double score = dot / sqrt(energy + 1e-9);
        // ties (silence): the one nearest the ideal source
        if (score > bestScore + 1e-12 ||
            (fabs(score - bestScore) <= 1e-12 && best >= 0 && labs(lo + (long)d * kDec - center) < labs(lo + (long)best * kDec - center))) {
            bestScore = score;
            best = d;
        }
    }
    long src = lo + (long)best * kDec;

    // refine at full rate
    long fine = src;
    double fineScore = -INFINITY;
    for (int d = -(kDec - 1); d <= kDec - 1; d++) {
        long c0 = src + d;
        if (c0 < s->base || c0 + kL > end) continue;
        double dot = 0, e = 0;
        for (int i = 0; i < kL; i++) {
            float x = mono(s, c0 + i);
            dot += (double)mono(s, natural + i) * x;
            e += (double)x * x;
        }
        double score = dot / sqrt(e + 1e-9);
        if (score > fineScore) {
            fineScore = score;
            fine = c0;
        }
    }
    return fine;
}

static void addFrame(DZStretch *s, long src) {
    long o = src - s->base;
    for (int c = 0; c < s->ch; c++) {
        const float *x = s->in[c] + o;
        float *a = s->acc[c];
        for (int i = 0; i < kN; i++) a[i] += s->win[i] * x[i];
    }
}

static void emitHop(DZStretch *s, float *const *out, int outStride, int at) {
    for (int c = 0; c < s->ch; c++) {
        float *a = s->acc[c];
        float *o = out[c];
        for (int i = 0; i < kHs; i++) o[(long)(at + i) * outStride] = a[i];
        memmove(a, a + kHs, sizeof(float) * kHs);
        memset(a + kHs, 0, sizeof(float) * kHs);
    }
}

int DZStretchCapacity(const DZStretch *s, int frames, double rate) {
    if (!s) return frames;
    if (rate < 0.5) rate = 0.5;
    double held = (double)s->len + (frames > 0 ? frames : 0);
    double n = held / rate;
    if (n < held) n = held;
    return (int)n + 2 * kN;
}

long DZStretchHeld(const DZStretch *s) {
    if (!s) return 0;
    long from = s->started ? s->prevSrc + kHs : lround(s->pos);
    long n = frameEnd(s) - from;
    return n > 0 ? n : 0;
}

int DZStretchProcess(DZStretch *s, const float *const *in, int frames, int inStride, double rate,
                     float *const *out, int outStride, int outCapacity) {
    if (!s || !append(s, in, frames, inStride)) return 0;
    if (rate < 0.5) rate = 0.5;
    if (rate > 2) rate = 2;
    if (outStride < 1) outStride = 1;
    int written = 0;
    for (;;) {
        long center = lround(s->pos);
        if (center + kDelta + kN > frameEnd(s) || written + kHs > outCapacity) break;
        long src;
        if (!s->started) {
            src = center < s->base ? s->base : center;
            // the first frame's rising half plus the falling half of a
            // frame just before it: the output starts as the input itself
            long o = src - s->base;
            for (int c = 0; c < s->ch; c++)
                for (int i = 0; i < kHs; i++) s->acc[c][i] += s->win[kHs + i] * s->in[c][o + i];
            s->started = 1;
        } else {
            src = bestSource(s, center);
        }
        addFrame(s, src);
        emitHop(s, out, outStride, written);
        written += kHs;
        s->prevSrc = src;
        s->pos += kHs * rate;
    }
    return written;
}

int DZStretchFinish(DZStretch *s, const float *const *in, int frames, int inStride,
                    float *const *out, int outStride, int outCapacity) {
    if (!s || !append(s, in, frames, inStride)) return 0;
    if (outStride < 1) outStride = 1;
    long end = frameEnd(s);
    long from = s->started ? s->prevSrc + kHs : lround(s->pos);
    if (from < s->base) from = s->base;
    long n = end - from;
    if (n > outCapacity) n = outCapacity;
    if (n < 0) n = 0;
    long o = from - s->base;
    // the pending half frame plus the rising half of the frame that would
    // follow it naturally is the input itself; after that, the input as is
    long h = s->started ? (n < kHs ? n : kHs) : 0;
    for (int c = 0; c < s->ch; c++) {
        const float *x = s->in[c] + o;
        float *dst = out[c];
        for (long i = 0; i < h; i++) dst[i * outStride] = s->acc[c][i] + s->win[i] * x[i];
        for (long i = h; i < n; i++) dst[i * outStride] = x[i];
        memset(s->acc[c], 0, sizeof(s->acc[c]));
    }
    s->base = end;
    s->len = 0;
    s->pos = (double)end;
    s->started = 0;
    return (int)n;
}
