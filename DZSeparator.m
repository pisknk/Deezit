#import "DZSeparator.h"
#import <Accelerate/Accelerate.h>
#import <CoreML/CoreML.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#include <stdatomic.h>
#import "DZVocalModel.h"
#import "DZDemucsModel.h"
#import "DZAudioParams.h"
#import "DZLog.h"
#import "DZAutoMix.h"

__thread int DZSingInside;

enum {
    kN = 4096,                 // STFT frame
    kH = 1024,                 // hop
    kHalf = kN / 2,            // packed real-FFT size
    kBins = 1024,              // bins the model sees (0 ... ~11 kHz)
    kT = 128,                  // model window (frames)
    kB = 32,                   // new frames per model run (~0.74 s)
    kL = 16,                   // look-ahead frames the model also sees (~0.37 s)
    kCtx = kT - kB - kL,       // past frames in the window (80)
    kSpan = (kB + kL - 1) * kH + kN,   // input samples one block needs
    kHiFrom = 768,             // mask above the model's range = its mean over 768..1023 (~8.3-11 kHz)
    kRing = 1 << 18,           // ~5.9 s per ring
    kRingMask = kRing - 1,
    kFade = 4096,              // raw -> processed crossfade when holding starts
    // MDX-Net 9482 (model lab): the same STFT, all 2048 bins (to ~22 kHz),
    // complex in and out, a 256-frame window: 208 past + the same 32 new + 16 ahead
    kMT = 256,
    kMBins = kHalf,
    kMCtx = kMT - kB - kL,
};
typedef enum { DZEngineSpleeter = 0, DZEngineMDX = 1 } DZEngine;
static const double kSampleRate = 44100;
static const double kStartHoldSeconds = 2.4;   // player queue needed before buffers are held
static const double kPanicSeconds = 0.35;      // player queue under this while holding: give up
static const float kOlaNorm = 1.5f;            // sum of Hann^2 at 75 % overlap

#pragma mark - shared FFT

static vDSP_DFT_Setup sFwd, sInv;
static float sWindow[kN];
static float sFwdScale = 2, sRoundTrip = 1;

static void rfft(const float *in, float *re, float *im, float *tmpRe, float *tmpIm) {
    DSPSplitComplex split = { tmpRe, tmpIm };
    vDSP_ctoz((const DSPComplex *)in, 2, &split, 1, kHalf);
    vDSP_DFT_Execute(sFwd, tmpRe, tmpIm, re, im);
}

static void irfft(const float *re, const float *im, float *out, float *tmpRe, float *tmpIm) {
    vDSP_DFT_Execute(sInv, re, im, tmpRe, tmpIm);
    DSPSplitComplex split = { tmpRe, tmpIm };
    vDSP_ztoc(&split, 1, (DSPComplex *)out, 2, kHalf);
}

// vDSP's packed real DFT scales differently from the textbook DFT (forward
// by 2, round trip by N-ish); measure both once instead of trusting a constant.
static BOOL setupFFT(void) {
    static dispatch_once_t once;
    static BOOL ok;
    dispatch_once(&once, ^{
        sFwd = vDSP_DFT_zrop_CreateSetup(NULL, kN, vDSP_DFT_FORWARD);
        sInv = vDSP_DFT_zrop_CreateSetup(sFwd, kN, vDSP_DFT_INVERSE);
        if (!sFwd || !sInv) return;
        for (int n = 0; n < kN; n++) sWindow[n] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * n / kN);   // periodic Hann
        float *x = calloc(kN, sizeof(float)), *y = calloc(kN, sizeof(float));
        float *re = calloc(kHalf, sizeof(float)), *im = calloc(kHalf, sizeof(float));
        float *tr = calloc(kHalf, sizeof(float)), *ti = calloc(kHalf, sizeof(float));
        x[0] = 1;                                   // impulse: textbook DFT is 1 in every bin
        rfft(x, re, im, tr, ti);
        sFwdScale = re[1];
        for (int n = 0; n < kN; n++) x[n] = sinf(0.37f * n) + 0.25f * cosf(1.91f * n);
        rfft(x, re, im, tr, ti);
        irfft(re, im, y, tr, ti);
        double num = 0, den = 0;
        for (int n = 0; n < kN; n++) { num += (double)y[n] * x[n]; den += (double)x[n] * x[n]; }
        sRoundTrip = (float)(num / den);
        free(x); free(y); free(re); free(im); free(tr); free(ti);
        ok = sFwdScale > 0 && sRoundTrip > 0;
        DZLog("sing: FFT ready (forward scale %.3f, round trip %.1f)", sFwdScale, sRoundTrip);
    });
    return ok;
}

#pragma mark - per-node state

@interface DZHeld : NSObject
@property (nonatomic, strong) AVAudioPCMBuffer *buffer;
@property (nonatomic) int64_t start;
@property (nonatomic) AVAudioFrameCount frames;
@property (nonatomic, copy) AVAudioNodeCompletionHandler completion;
@property (nonatomic) uint64_t song;   // AutoMix's note of which song it is (DZAutoMixTakePending)
@end
@implementation DZHeld
@end

@interface DZSepNode : NSObject {
@public
    os_unfair_lock lock;
    uint64_t gen;                 // analysis session; bumped on stop / Sing off
    uint64_t stopGen;             // bumped only by -stop: queued buffers from before it are dropped
    BOOL clearPending;            // the compute queue clears its rings / context before the next block
    int64_t inCount;              // samples appended this session
    int64_t nextFrame;            // next STFT frame to compute
    int64_t outReady;             // output samples [0, outReady) are final
    int64_t fadeStart;
    BOOL holding, computing, degraded;
    int pending;                  // schedule ops queued on schedQ
    float lastCut, lastBacking;
    _Atomic(int64_t) playerFrames;   // given to the player, completion not yet run
    float *inRing[2], *outRing[2];
    float *scratch[2];            // input span of one block
    float *specRe, *specIm;       // [ch][frame][kHalf]
    float *tmp[4];                // FFT temporaries + one time frame
    float *maskL, *maskR;         // one frame's vocal masks [kHalf], Nyquist in [0] of maskNyq
    float maskNyq[2];
    int engine;                   // DZEngine of this session (changing it starts a new session)
    float *hist;                  // MDX: [ch][kMT][re | im][kMBins], the model's window (lazily allocated)
    double inferMs;
    uint64_t blocks;
}
@property (nonatomic, weak) AVAudioPlayerNode *node;
@property (nonatomic) NSUInteger serial;
@property (nonatomic, strong) NSMutableArray<DZHeld *> *held;
@property (nonatomic, strong) dispatch_queue_t schedQ, computeQ;
@property (nonatomic, strong) MLMultiArray *input;   // [1, 2, kT, kBins], also the context window
@property (nonatomic, strong) MLMultiArray *mdxInput; // [1, 4, kMBins, kMT] L.re L.im R.re R.im, in the model's type
@end

@implementation DZSepNode
- (void)dealloc {
    for (int c = 0; c < 2; c++) { free(inRing[c]); free(outRing[c]); free(scratch[c]); }
    free(specRe); free(specIm);
    for (int i = 0; i < 4; i++) free(tmp[i]);
    free(maskL); free(maskR); free(hist);
}
@end

static void *kDZSepKey = &kDZSepKey;
static NSUInteger sNodes;
static NSString *sLastEvent;
static __weak DZSepNode *sLastActive;

static void note(NSString *event) {
    @synchronized ([DZSepNode class]) { sLastEvent = [event copy]; }
    DZLog("sing: %@", event);
}

static DZSepNode *makeNode(AVAudioPlayerNode *node) {
    DZSepNode *s = [DZSepNode new];
    s->lock = OS_UNFAIR_LOCK_INIT;
    for (int c = 0; c < 2; c++) {
        s->inRing[c] = calloc(kRing, sizeof(float));
        s->outRing[c] = calloc(kRing, sizeof(float));
        s->scratch[c] = calloc(kSpan, sizeof(float));
    }
    s->specRe = calloc(2 * kB * kHalf, sizeof(float));
    s->specIm = calloc(2 * kB * kHalf, sizeof(float));
    for (int i = 0; i < 4; i++) s->tmp[i] = calloc(kN, sizeof(float));
    s->maskL = calloc(kHalf, sizeof(float));
    s->maskR = calloc(kHalf, sizeof(float));
    NSError *err = nil;
    s.input = [[MLMultiArray alloc] initWithShape:@[@1, @2, @(kT), @(kBins)] dataType:MLMultiArrayDataTypeFloat32 error:&err];
    if (!s.input || !s->inRing[1] || !s->outRing[1] || !s->specIm || !s->tmp[3] || !s->maskR) return nil;
    memset(s.input.dataPointer, 0, sizeof(float) * 2 * kT * kBins);
    s.node = node;
    s.held = [NSMutableArray array];
    s.schedQ = dispatch_queue_create("com.pisknk.deezit.sing.schedule", DISPATCH_QUEUE_SERIAL);
    s.computeQ = dispatch_queue_create("com.pisknk.deezit.sing.compute",
                                       dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    @synchronized ([DZSepNode class]) { s.serial = ++sNodes; }
    return s;
}

// Call with the lock held. Only the compute queue touches the output ring and
// the model's context window, so it clears them itself (clearPending) before
// the new session's first block, after any stale pass has finished.
static void resetSession(DZSepNode *s) {
    s->gen++;
    s->inCount = s->nextFrame = s->outReady = 0;
    s->fadeStart = 0;
    s->holding = NO;
    s->computing = NO;
    s->lastCut = 0;
    s->lastBacking = 0;
    s->clearPending = YES;
}

// Queues one buffer for the player, in order. Call with the lock held. If the
// node was stopped (stop / seek / skip) before it runs, the buffer isn't
// played but Deezer's completion still runs, so its bookkeeping stays right.
// `song` is AutoMix's note of which song the buffer is (taken on Deezer's
// thread, handed back on this queue right before the buffer is scheduled).
static void enqueueSchedule(DZSepNode *s, AVAudioPCMBuffer *buffer, AVAudioNodeCompletionHandler handler, uint64_t song) {
    s->pending++;
    uint64_t stopGen = s->stopGen;
    AVAudioFrameCount frames = buffer.frameLength;
    dispatch_async(s.schedQ, ^{
        AVAudioPlayerNode *node = s.node;
        os_unfair_lock_lock(&s->lock);
        BOOL stale = s->stopGen != stopGen;
        os_unfair_lock_unlock(&s->lock);
        if (stale || !node) {
            if (handler) handler();
        } else {
            atomic_fetch_add(&s->playerFrames, (int64_t)frames);
            DZSingInside++;
            DZAutoMixSetPending(song);
            [node scheduleBuffer:buffer atTime:nil options:0 completionHandler:^{
                atomic_fetch_sub(&s->playerFrames, (int64_t)frames);
                if (handler) handler();
            }];
            DZAutoMixSetPending(0);
            DZSingInside--;
        }
        os_unfair_lock_lock(&s->lock);
        s->pending--;
        os_unfair_lock_unlock(&s->lock);
    });
}

// Hands every held buffer to the player as it is (unprocessed). Lock held.
static void releaseHeldRaw(DZSepNode *s) {
    for (DZHeld *h in s.held) enqueueSchedule(s, h.buffer, h.completion, h.song);
    [s.held removeAllObjects];
}

#pragma mark - model

// Reads the vocal mask at (channel, time, bin), whatever the output's type/strides.
typedef struct { const void *base; MLMultiArrayDataType type; long s1, s2, s3; } DZMaskView;

static inline float maskAt(const DZMaskView *v, int c, int t, int k) {
    long i = c * v->s1 + t * v->s2 + k * v->s3;
    switch (v->type) {
        case MLMultiArrayDataTypeFloat32: return ((const float *)v->base)[i];
        case MLMultiArrayDataTypeDouble: return (float)((const double *)v->base)[i];
        default: return (float)((const _Float16 *)v->base)[i];
    }
}

#pragma mark - engine

// The engine Sing uses now and its model (nil while it loads). MDX-Net when
// picked and downloaded; else Spleeter when downloaded; else MDX-Net if that
// is all there is.
static MLModel *engineModel(DZEngine *engine) {
    BOOL mdx = DZLabModelInstalled(kDZLabMDX);
    if (mdx && (DZPrefsAudioParams().singModel == 1 || DZVocalModelGetState() != DZVocalModelReady)) {
        *engine = DZEngineMDX;
        return DZLabModelGet(kDZLabMDX);
    }
    *engine = DZEngineSpleeter;
    return DZVocalModelGetState() == DZVocalModelReady ? DZVocalModelGet() : nil;
}

static MLModel *modelFor(DZEngine engine) {
    return engine == DZEngineMDX ? DZLabModelGet(kDZLabMDX) : DZVocalModelGet();
}

static const char *engineName(int engine) { return engine == DZEngineMDX ? "MDX-Net" : "Spleeter"; }

#pragma mark - compute

static void runCompute(DZSepNode *s, uint64_t gen);

// Starts a compute pass when a block's worth of input is in. Lock held.
static void kickCompute(DZSepNode *s) {
    if (s->computing) return;
    if (s->inCount < s->nextFrame * kH + kSpan) return;      // the block plus its look-ahead
    s->computing = YES;
    uint64_t gen = s->gen;
    dispatch_async(s.computeQ, ^{ runCompute(s, gen); });
}

// Removes vocals from one stereo bin pair, in place. vL/vR = the vocal part
// (mask * mix); its centre (vL+vR)/2 is the lead, its sides (vL-vR)/2 the
// side-panned backing vocals. cutLead removes the centre, cutSide the sides
// (cutSide = cutLead when backing vocals aren't kept, so it's mask removal).
static inline void unmix(float *l, float *r, float mL, float mR, float cutLead, float cutSide) {
    float vL = mL * *l, vR = mR * *r;
    float mid = 0.5f * (vL + vR), side = 0.5f * (vL - vR);
    *l -= cutLead * mid + cutSide * side;
    *r -= cutLead * mid - cutSide * side;
}

// Strength: how sure the model must be before a cell counts as voice. Below
// `lo` the cell is left alone, above `hi` it is fully voice, linear between.
// Instruments the model only half-mistakes for voice (violins, claps, synth
// leads) sit in the low range and survive Gentle / Normal. `hiBand` scales
// the mask used above the model's ~11 kHz range (the singer's "s" / "t", but
// also claps and cymbals).
typedef struct { float lo, hi, hiBand; } DZStrength;
static const DZStrength kDZStrengths[3] = {
    { 0.45f, 0.85f, 0.0f },     // Gentle
    { 0.25f, 0.80f, 0.5f },     // Normal
    { 0.00f, 1.00f, 1.0f },     // Strong (the model's mask as is)
};

static inline float shapeMask(float m, const DZStrength *k) {
    float v = (m - k->lo) / (k->hi - k->lo);
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

// MDX-Net: the model's window and input, made on first use (8 MB each).
static BOOL mdxBuffers(DZSepNode *s, MLModel *model) {
    if (!s->hist) {
        s->hist = calloc((size_t)2 * kMT * 2 * kMBins, sizeof(float));
        if (!s->hist) return NO;
    }
    MLMultiArrayDataType type = MLMultiArrayDataTypeFloat32;
    if (@available(iOS 16.0, *)) {
        MLMultiArrayConstraint *c = model.modelDescription.inputDescriptionsByName[@"input"].multiArrayConstraint;
        if (c.dataType == MLMultiArrayDataTypeFloat16) type = MLMultiArrayDataTypeFloat16;
    }
    if (!s.mdxInput || s.mdxInput.dataType != type) {
        NSError *err = nil;
        s.mdxInput = [[MLMultiArray alloc] initWithShape:@[@1, @4, @(kMBins), @(kMT)] dataType:type error:&err];
    }
    return s.mdxInput != nil;
}

// MDX-Net: the window [ch][t][re | im][k] -> the model's [1, 4, k, t] input.
static void mdxFill(DZSepNode *s) {
    BOOL half = s.mdxInput.dataType != MLMultiArrayDataTypeFloat32;
    float *f32 = half ? NULL : (float *)s.mdxInput.dataPointer;
    _Float16 *f16 = half ? (_Float16 *)s.mdxInput.dataPointer : NULL;
    for (int c = 0; c < 2; c++) {
        for (int part = 0; part < 2; part++) {
            long plane = (long)(2 * c + part) * kMBins * kMT;
            for (int t = 0; t < kMT; t++) {
                const float *src = s->hist + (((long)c * kMT + t) * 2 + part) * kMBins;
                if (half) for (int k = 0; k < kMBins; k++) f16[plane + (long)k * kMT + t] = (_Float16)src[k];
                else for (int k = 0; k < kMBins; k++) f32[plane + (long)k * kMT + t] = src[k];
            }
        }
    }
}

static void runCompute(DZSepNode *s, uint64_t gen) {
    const int span = kSpan;
    for (;;) {
        os_unfair_lock_lock(&s->lock);
        if (s->gen != gen) { os_unfair_lock_unlock(&s->lock); return; }
        if (s->clearPending) {
            s->clearPending = NO;
            for (int c = 0; c < 2; c++) memset(s->outRing[c], 0, kRing * sizeof(float));
            memset(s.input.dataPointer, 0, sizeof(float) * 2 * kT * kBins);
            if (s->hist) memset(s->hist, 0, sizeof(float) * 2 * kMT * 2 * kMBins);
        }
        int64_t f0 = s->nextFrame, from = f0 * kH;
        if (s->inCount < from + span || s->inCount - from > kRing) {
            s->computing = NO;
            os_unfair_lock_unlock(&s->lock);
            return;
        }
        for (int c = 0; c < 2; c++) {
            for (int i = 0; i < span; i++) s->scratch[c][i] = s->inRing[c][(from + i) & kRingMask];
        }
        float cutPrev = s->lastCut, backPrev = s->lastBacking;
        DZEngine engine = (DZEngine)s->engine;
        os_unfair_lock_unlock(&s->lock);

        DZAudioParams params = DZPrefsAudioParams();
        float cut = params.vocalCut, backing = params.backingKeep;
        const DZStrength *strength = &kDZStrengths[params.singStrength < 0 ? 0 : params.singStrength > 2 ? 2 : params.singStrength];
        MLModel *model = modelFor(engine);
        if (!model || (engine == DZEngineMDX && !mdxBuffers(s, model))) {
            os_unfair_lock_lock(&s->lock);
            if (s->gen == gen) { s->degraded = YES; releaseHeldRaw(s); s->computing = NO; }
            os_unfair_lock_unlock(&s->lock);
            note([NSString stringWithFormat:@"%s unavailable, playing without Sing", engineName(engine)]);
            return;
        }

        // Model window = frames [f0 - ctx, f0 + 48): the past, the 32 new ones,
        // 16 look-ahead. Slide it by 32 and (re)compute frames f0 ... f0+47;
        // the complex spectra are kept for the 32 new ones only.
        // Spleeter takes magnitudes (1024 bins), MDX-Net the complex spectrum
        // (2048 bins, DC's imaginary part 0, Nyquist dropped), both unscaled.
        float *mag = (float *)s.input.dataPointer;
        for (int c = 0; c < 2; c++) {
            float *m = mag + c * kT * kBins;
            float *h = engine == DZEngineMDX ? s->hist + (long)c * kMT * 2 * kMBins : NULL;
            if (h) memmove(h, h + (long)kB * 2 * kMBins, sizeof(float) * (kMT - kB) * 2 * kMBins);
            else memmove(m, m + kB * kBins, sizeof(float) * (kT - kB) * kBins);
            for (int j = 0; j < kB + kL; j++) {
                float *frame = s->tmp[2];
                vDSP_vmul(s->scratch[c] + j * kH, 1, sWindow, 1, frame, 1, kN);
                float *re, *im;
                if (j < kB) {
                    re = s->specRe + (c * kB + j) * kHalf;
                    im = s->specIm + (c * kB + j) * kHalf;
                } else {
                    re = s->tmp[3];
                    im = s->tmp[3] + kHalf;
                }
                rfft(frame, re, im, s->tmp[0], s->tmp[1]);
                if (h) {
                    float *rowRe = h + ((long)(kMCtx + j) * 2) * kMBins, *rowIm = rowRe + kMBins;
                    float inv = 1.0f / sFwdScale;
                    vDSP_vsmul(re, 1, &inv, rowRe, 1, kMBins);
                    vDSP_vsmul(im, 1, &inv, rowIm, 1, kMBins);
                    rowIm[0] = 0;                                         // packed Nyquist, not DC's imaginary part
                } else {
                    float *row = m + (kCtx + j) * kBins;
                    row[0] = fabsf(re[0]) / sFwdScale;                    // DC (im[0] holds Nyquist)
                    for (int k = 1; k < kBins; k++) row[k] = hypotf(re[k], im[k]) / sFwdScale;
                }
            }
        }

        CFTimeInterval t0 = CACurrentMediaTime();
        NSError *err = nil;
        MLDictionaryFeatureProvider *in;
        if (engine == DZEngineMDX) {
            mdxFill(s);
            in = [[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{ @"input": [MLFeatureValue featureValueWithMultiArray:s.mdxInput] } error:&err];
        } else {
            in = [[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{ @"magnitude": [MLFeatureValue featureValueWithMultiArray:s.input] } error:&err];
        }
        id<MLFeatureProvider> out = in ? [model predictionFromFeatures:in error:&err] : nil;
        MLMultiArray *masks = [out featureValueForName:engine == DZEngineMDX ? @"output" : @"vocal_mask"].multiArrayValue;
        double ms = (CACurrentMediaTime() - t0) * 1000;
        if (!masks || masks.strides.count != 4) {
            os_unfair_lock_lock(&s->lock);
            if (s->gen == gen) { s->degraded = YES; releaseHeldRaw(s); s->computing = NO; }
            os_unfair_lock_unlock(&s->lock);
            note([NSString stringWithFormat:@"%s run failed (%@), playing without Sing", engineName(engine),
                  err.localizedDescription ?: @"no output"]);
            return;
        }
        DZMaskView view = { masks.dataPointer, masks.dataType,
                            masks.strides[1].longValue, masks.strides[2].longValue, masks.strides[3].longValue };

        // remove the vocals bin by bin, inverse STFT, overlap-add
        float *frameOut = s->tmp[3];
        float synth = 1.0f / (sRoundTrip * kOlaNorm);
        os_unfair_lock_lock(&s->lock);
        if (s->gen != gen) { os_unfair_lock_unlock(&s->lock); return; }
        os_unfair_lock_unlock(&s->lock);
        // (the OLA below only touches the out ring, which only this queue writes)
        for (int j = 0; j < kB; j++) {
            float step = (float)(j + 1) / kB;                     // glide setting changes over the block
            float cutLead = cutPrev + (cut - cutPrev) * step;
            float keep = backPrev + (backing - backPrev) * step;
            float cutSide = cutLead * (1.0f - keep);
            float *reL = s->specRe + j * kHalf, *imL = s->specIm + j * kHalf;
            float *reR = s->specRe + (kB + j) * kHalf, *imR = s->specIm + (kB + j) * kHalf;

            if (engine == DZEngineMDX) {
                // MDX-Net gives the vocals' spectrum: their share of each bin,
                // |vocals| / |mix| (at most 1), is the mask, shaped by Strength.
                // It covers every bin, so no high-band stand-in is needed.
                int t = kMCtx + j;
                for (int c = 0; c < 2; c++) {
                    const float *re = c ? reR : reL, *im = c ? imR : imL;
                    float *mk = c ? s->maskR : s->maskL;
                    for (int k = 0; k < kMBins; k++) {
                        float vr = maskAt(&view, 2 * c, k, t), vi = maskAt(&view, 2 * c + 1, k, t);
                        float xr = re[k] / sFwdScale, xi = k ? im[k] / sFwdScale : 0;
                        float mix = hypotf(xr, xi);
                        float m = mix > 1e-9f ? hypotf(vr, vi) / mix : 0;
                        mk[k] = shapeMask(m > 1 ? 1 : m, strength);
                    }
                    s->maskNyq[c] = mk[kMBins - 1];
                }
            } else {
                // above the model's range (~11 kHz up): its mean mask over ~8.3-11 kHz,
                // so the singer's "s" / "t" go with the voice
                int t = kCtx + j;
                float hiL = 0, hiR = 0;
                if (strength->hiBand > 0) {
                    for (int k = kHiFrom; k < kBins; k++) {
                        hiL += shapeMask(maskAt(&view, 0, t, k), strength);
                        hiR += shapeMask(maskAt(&view, 1, t, k), strength);
                    }
                    hiL *= strength->hiBand / (kBins - kHiFrom);
                    hiR *= strength->hiBand / (kBins - kHiFrom);
                }
                for (int k = 0; k < kHalf; k++) {
                    s->maskL[k] = k < kBins ? shapeMask(maskAt(&view, 0, t, k), strength) : hiL;
                    s->maskR[k] = k < kBins ? shapeMask(maskAt(&view, 1, t, k), strength) : hiR;
                }
                s->maskNyq[0] = hiL;
                s->maskNyq[1] = hiR;
            }

            unmix(&reL[0], &reR[0], s->maskL[0], s->maskR[0], cutLead, cutSide);                   // DC
            unmix(&imL[0], &imR[0], s->maskNyq[0], s->maskNyq[1], cutLead, cutSide);              // Nyquist
            for (int k = 1; k < kHalf; k++) {
                unmix(&reL[k], &reR[k], s->maskL[k], s->maskR[k], cutLead, cutSide);
                unmix(&imL[k], &imR[k], s->maskL[k], s->maskR[k], cutLead, cutSide);
            }

            int64_t base = (f0 + j) * kH;
            for (int c = 0; c < 2; c++) {
                float *re = c ? reR : reL, *im = c ? imR : imL;
                irfft(re, im, frameOut, s->tmp[0], s->tmp[1]);
                float *ring = s->outRing[c];
                // this frame is the first to reach its last hop: clear it before adding
                for (int n = kN - kH; n < kN; n++) ring[(base + n) & kRingMask] = 0;
                for (int n = 0; n < kN; n++) ring[(base + n) & kRingMask] += frameOut[n] * sWindow[n] * synth;
            }
        }

        os_unfair_lock_lock(&s->lock);
        if (s->gen != gen) { os_unfair_lock_unlock(&s->lock); return; }
        s->nextFrame = f0 + kB;
        s->outReady = s->nextFrame * kH;          // nothing later overlaps these samples any more
        s->lastCut = cut;
        s->lastBacking = backing;
        s->inferMs = s->blocks ? s->inferMs * 0.9 + ms * 0.1 : ms;
        s->blocks++;
        while (s.held.count) {
            DZHeld *h = s.held.firstObject;
            if (h.start + h.frames > s->outReady) break;
            float *const *ch = h.buffer.floatChannelData;
            for (int c = 0; c < 2; c++) {
                float *dst = ch[c];
                const float *ring = s->outRing[c];
                for (AVAudioFrameCount i = 0; i < h.frames; i++) {
                    int64_t p = h.start + i;
                    float processed = ring[p & kRingMask];
                    if (p < s->fadeStart + kFade) {
                        float a = (float)(p - s->fadeStart) / kFade;
                        if (a < 0) a = 0;
                        dst[i] = dst[i] * (1 - a) + processed * a;
                    } else {
                        dst[i] = processed;
                    }
                }
            }
            enqueueSchedule(s, h.buffer, h.completion, h.song);
            [s.held removeObjectAtIndex:0];
        }
        os_unfair_lock_unlock(&s->lock);
    }
}

#pragma mark - hooks' entry points

static BOOL formatOK(AVAudioPCMBuffer *b) {
    AVAudioFormat *f = b.format;
    return f.channelCount == 2 && f.commonFormat == AVAudioPCMFormatFloat32 && !f.isInterleaved &&
           fabs(f.sampleRate - kSampleRate) < 1 && b.frameLength > 0 && b.frameLength <= 16384 && b.floatChannelData;
}

BOOL DZSingSchedule(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer, AVAudioNodeCompletionHandler handler) {
    DZSepNode *s = objc_getAssociatedObject(node, kDZSepKey);
    float cut = DZPrefsAudioParams().vocalCut;
    BOOL wanted = cut > 0.001f;
    DZEngine engine = DZEngineSpleeter;
    MLModel *model = wanted ? engineModel(&engine) : nil;
    BOOL active = wanted && model && formatOK(buffer) && setupFFT();
    if (!s && !active) return NO;
    if (!s) {
        s = makeNode(node);
        if (!s) return NO;
        s->engine = engine;
        objc_setAssociatedObject(node, kDZSepKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        note([NSString stringWithFormat:@"on for player #%lu", (unsigned long)s.serial]);
    }
    // from here Sing schedules this buffer later on its own queue: AutoMix's
    // note of which song it is goes with it
    uint64_t song = DZAutoMixTakePending();

    os_unfair_lock_lock(&s->lock);
    if (!active || s->degraded) {
        // Sing off (or given up): let held buffers go as they are, end the session
        if (s->inCount > 0 || s.held.count) resetSession(s);
        releaseHeldRaw(s);
        enqueueSchedule(s, buffer, handler, song);
        os_unfair_lock_unlock(&s->lock);
        return YES;
    }

    if (s->engine != (int)engine) {
        // other model: its window means nothing to this one, start over
        // (held buffers go as they are; the new one warms up like at a track start)
        if (s->inCount > 0 || s.held.count) resetSession(s);
        releaseHeldRaw(s);
        s->engine = engine;
        note([NSString stringWithFormat:@"player #%lu now uses %s", (unsigned long)s.serial, engineName(engine)]);
    }

    AVAudioFrameCount n = buffer.frameLength;
    int64_t start = s->inCount;
    float *const *ch = buffer.floatChannelData;
    for (int c = 0; c < 2; c++) {
        float *ring = s->inRing[c];
        for (AVAudioFrameCount i = 0; i < n; i++) ring[(start + i) & kRingMask] = ch[c][i];
    }
    s->inCount += n;
    double queued = atomic_load(&s->playerFrames) / kSampleRate;

    // hold only once the player is well fed and the model has already run once
    // in this session (the first Core ML run can be slow)
    if (!s->holding && queued >= kStartHoldSeconds && start >= 2 * kN && s->blocks > 0) {
        s->holding = YES;
        s->fadeStart = start;
        sLastActive = s;
    }
    if (s->holding && s.held.count && queued < kPanicSeconds) {
        s->degraded = YES;
        releaseHeldRaw(s);
        enqueueSchedule(s, buffer, handler, song);
        os_unfair_lock_unlock(&s->lock);
        note([NSString stringWithFormat:@"player #%lu queue fell to %.2f s, playing this one without Sing",
              (unsigned long)s.serial, queued]);
        return YES;
    }
    if (s->holding) {
        DZHeld *h = [DZHeld new];
        h.buffer = buffer;
        h.start = start;
        h.frames = n;
        h.completion = handler;
        h.song = song;
        [s.held addObject:h];
    } else {
        enqueueSchedule(s, buffer, handler, song);
    }
    kickCompute(s);
    os_unfair_lock_unlock(&s->lock);
    return YES;
}

void DZSingStop(AVAudioPlayerNode *node) {
    DZSepNode *s = objc_getAssociatedObject(node, kDZSepKey);
    if (!s) return;
    NSArray<DZHeld *> *dropped;
    os_unfair_lock_lock(&s->lock);
    dropped = [s.held copy];
    [s.held removeAllObjects];
    resetSession(s);
    s->stopGen++;
    s->degraded = NO;                 // a new track / seek gets a fresh try
    os_unfair_lock_unlock(&s->lock);
    if (dropped.count) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (DZHeld *h in dropped) if (h.completion) h.completion();
        });
    }
}

NSString *DZSingStatus(void) {
    DZVocalModelState state = DZVocalModelGetState();
    float cut = DZPrefsAudioParams().vocalCut;
    if (state != DZVocalModelReady && !DZLabModelInstalled(kDZLabMDX))
        return [@"sing: model " stringByAppendingString:DZVocalModelStatusText()];
    if (cut <= 0.001f) return @"sing: model ready, vocals at 100% (off)";
    DZSepNode *s;
    NSString *last;
    @synchronized ([DZSepNode class]) { s = sLastActive; last = sLastEvent; }
    if (!s) return [NSString stringWithFormat:@"sing: vocals %d%%, waiting for playback%@", (int)lroundf((1 - cut) * 100),
                    last ? [@" · " stringByAppendingString:last] : @""];
    os_unfair_lock_lock(&s->lock);
    NSString *line = [NSString stringWithFormat:@"sing (%s): vocals %d%%, backing %d%% kept, %@ · player #%lu %@ · held %.2f s · "
                      @"player queue %.2f s · %llu blocks · model %.0f ms%@",
                      engineName(s->engine), (int)lroundf((1 - cut) * 100), (int)lroundf(DZPrefsAudioParams().backingKeep * 100),
                      @[@"gentle", @"normal", @"strong"][MIN(MAX(DZPrefsAudioParams().singStrength, 0), 2)], (unsigned long)s.serial,
                      s->degraded ? @"PAUSED" : (s->holding ? @"separating" : @"warming up"),
                      s.held.count ? (s->inCount - s.held.firstObject.start) / kSampleRate : 0.0,
                      atomic_load(&s->playerFrames) / kSampleRate, (unsigned long long)s->blocks, s->inferMs,
                      last ? [@" · " stringByAppendingString:last] : @""];
    os_unfair_lock_unlock(&s->lock);
    return line;
}
