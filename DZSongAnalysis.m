#import "DZSongAnalysis.h"
#import <Accelerate/Accelerate.h>

static const int kInfoVersion = 1;

#pragma mark - DZSongInfo

@interface DZSongInfo ()
- (instancetype)copyInfo;
@end

@implementation DZSongInfo

- (instancetype)init {
    if ((self = [super init])) {
        _source = @"";
        _bars = @[];
    }
    return self;
}

static double num(id v) { return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0; }

+ (instancetype)fromPlist:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || num(d[@"v"]) != kInfoVersion) return nil;
    DZSongInfo *i = [DZSongInfo new];
    i.source = [d[@"source"] isKindOfClass:[NSString class]] ? d[@"source"] : @"";
    i.duration = num(d[@"duration"]);
    i.bpm = num(d[@"bpm"]);
    i.musicStart = num(d[@"musicStart"]);
    i.musicEnd = num(d[@"musicEnd"]);
    i.beatConfidence = num(d[@"conf"]);
    NSMutableArray *bars = [NSMutableArray array];
    if ([d[@"bars"] isKindOfClass:[NSArray class]])
        for (id b in d[@"bars"]) if ([b isKindOfClass:[NSNumber class]]) [bars addObject:b];
    i.bars = bars;
    return i.duration > 0 ? i : nil;
}

- (NSDictionary *)plist {
    return @{ @"v": @(kInfoVersion), @"source": self.source, @"duration": @(self.duration), @"bpm": @(self.bpm),
              @"musicStart": @(self.musicStart), @"musicEnd": @(self.musicEnd), @"bars": self.bars ?: @[],
              @"conf": @(self.beatConfidence) };
}

- (NSNumber *)firstBarFrom:(double)t {
    for (NSNumber *b in self.bars) if (b.doubleValue >= t) return b;
    return nil;
}

- (instancetype)copyInfo {
    DZSongInfo *i = [DZSongInfo fromPlist:[self plist]];
    return i ?: [DZSongInfo new];
}

@end

#pragma mark - analyzer

// Short-time spectra of the mono mix: 1024-sample Hann frames every 512
// samples (11.6 ms at 44.1 kHz). Per frame it keeps the level, the
// log-spectral flux weighted equally per octave (onsets) and the rise in
// magnitude below ~200 Hz (kick / bass, for the downbeats). Checked on
// synthetic songs at 67-128 BPM with a numpy port: tempo within 0.5 %, bars
// within 8 ms. -finish turns those into:
//   - where the music starts and winds down: the level per 0.25 s against the
//     song's typical loud level (its 75th percentile)
//   - the tempo: autocorrelation of the onset curve, weighted towards 120 BPM
//   - the beats: dynamic-programming beat tracking (D. Ellis, "Beat Tracking
//     by Dynamic Programming", 2007) - beats on onsets, spaced by the tempo
//   - the bars: every 4th beat, starting at the beat whose low end hits hardest
enum { kFN = 1024, kHop = 512, kHalfN = 512, kFluxBins = 256, kBassBins = 5 };

@implementation DZSongAnalyzer {
    double _sr;
    vDSP_DFT_Setup _dft;
    float _win[kFN], _frame[kFN], _tmp[kFN];
    float _pend[kHop];
    int _pendN;
    float _prevLog[kHalfN], _prevMag[kHalfN];
    float _re[kHalfN], _im[kHalfN], _ire[kHalfN], _iim[kHalfN], _mag[kHalfN];
    BOOL _havePrev;
    long long _fed;
    NSMutableData *_onset, *_bass, *_ms;
}

- (instancetype)initWithSampleRate:(double)sampleRate {
    if ((self = [super init])) {
        _sr = sampleRate > 1000 ? sampleRate : 44100;
        _dft = vDSP_DFT_zrop_CreateSetup(NULL, kFN, vDSP_DFT_FORWARD);
        for (int n = 0; n < kFN; n++) _win[n] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * n / kFN);
        _onset = [NSMutableData data];
        _bass = [NSMutableData data];
        _ms = [NSMutableData data];
    }
    return self;
}

- (void)dealloc {
    if (_dft) vDSP_DFT_DestroySetup(_dft);
}

- (double)seconds {
    return _fed / _sr;
}

- (void)processHop {
    memmove(_frame, _frame + kHop, (kFN - kHop) * sizeof(float));
    memcpy(_frame + kFN - kHop, _pend, kHop * sizeof(float));
    float ms = 0;
    vDSP_measqv(_pend, 1, &ms, kHop);

    float flux = 0, bass = 0;
    if (_dft) {
        vDSP_vmul(_frame, 1, _win, 1, _tmp, 1, kFN);
        DSPSplitComplex in = { _ire, _iim };
        vDSP_ctoz((const DSPComplex *)_tmp, 2, &in, 1, kHalfN);
        vDSP_DFT_Execute(_dft, _ire, _iim, _re, _im);
        _re[0] = 0;   // DC and Nyquist (packed in bin 0) carry no onsets
        _im[0] = 0;
        DSPSplitComplex out = { _re, _im };
        vDSP_zvabs(&out, 1, _mag, 1, kHalfN);
        // low end on plain magnitudes (a louder kick counts more: downbeats)
        if (_havePrev) {
            for (int k = 1; k <= kBassBins; k++) {
                float d = _mag[k] - _prevMag[k];
                if (d > 0) bass += d;
            }
        }
        memcpy(_prevMag, _mag, sizeof(_prevMag));
        float gain = 10;
        vDSP_vsmul(_mag, 1, &gain, _mag, 1, kHalfN);
        int n = kHalfN;
        vvlog1pf(_mag, _mag, &n);
        // onsets on log magnitudes, each bin weighted 1/k so every octave
        // counts the same (else hi-hats outvote the kick and the tempo doubles)
        if (_havePrev) {
            for (int k = 1; k < kFluxBins; k++) {
                float d = _mag[k] - _prevLog[k];
                if (d > 0) flux += d / k;
            }
        }
        memcpy(_prevLog, _mag, sizeof(_prevLog));
        _havePrev = YES;
    }
    [_onset appendBytes:&flux length:sizeof(float)];
    [_bass appendBytes:&bass length:sizeof(float)];
    [_ms appendBytes:&ms length:sizeof(float)];
}

- (void)addChannels:(float *const *)channels count:(int)channelCount frames:(int)frames stride:(int)stride {
    if (channelCount < 1 || frames < 1) return;
    if (stride < 1) stride = 1;
    float scale = 1.0f / channelCount;
    for (int i = 0; i < frames; i++) {
        float x = 0;
        for (int c = 0; c < channelCount; c++) x += channels[c][(long)i * stride];
        _pend[_pendN++] = x * scale;
        if (_pendN == kHop) {
            [self processHop];
            _pendN = 0;
        }
    }
    _fed += frames;
}

static int cmpFloat(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

- (DZSongInfo *)finish {
    long N = (long)(_onset.length / sizeof(float));
    double hopSec = kHop / _sr;
    if (N * hopSec < 30) return nil;
    const float *on = _onset.bytes, *bassFlux = _bass.bytes, *ms = _ms.bytes;

    // level per 0.25 s, and the song's typical loud level
    int W = MAX(1, (int)lround(0.25 / hopSec));
    long nw = N / W;
    float *lvl = malloc(nw * sizeof(float)), *loud = malloc(nw * sizeof(float));
    long nLoud = 0;
    for (long i = 0; i < nw; i++) {
        double m = 0;
        for (int j = 0; j < W; j++) m += ms[i * W + j];
        m /= W;
        lvl[i] = (float)(10 * log10(m > 1e-12 ? m : 1e-12));
        if (lvl[i] > -70) loud[nLoud++] = lvl[i];
    }
    if (nLoud < 40) { free(lvl); free(loud); return nil; }
    qsort(loud, nLoud, sizeof(float), cmpFloat);
    float ref = loud[(long)(0.75 * (nLoud - 1))];
    free(loud);
    long startW = 0, endW = nw - 1;
    while (startW < nw && lvl[startW] < ref - 20) startW++;
    while (endW > startW && lvl[endW] < ref - 12) endW--;
    free(lvl);

    DZSongInfo *info = [DZSongInfo new];
    info.source = @"deezit";
    info.duration = _fed / _sr;
    info.musicStart = startW * W * hopSec;
    info.musicEnd = MIN(info.duration, (endW + 1) * W * hopSec);
    long startF = startW * W, endF = MIN(N - 1, (endW + 1) * W);
    long len = endF - startF + 1;
    if (len * hopSec < 20) return info;

    // onset curve: flux above its local average, in units of its spread
    float *o = calloc(N, sizeof(float));
    double *prefix = malloc((N + 1) * sizeof(double));
    prefix[0] = 0;
    for (long t = 0; t < N; t++) prefix[t + 1] = prefix[t] + on[t];
    for (long t = 0; t < N; t++) {
        long a = MAX(0, t - 8), b = MIN(N, t + 9);
        float avg = (float)((prefix[b] - prefix[a]) / (b - a));
        o[t] = MAX(0.0f, on[t] - avg);
    }
    free(prefix);
    float mean = 0, sd = 0;
    vDSP_normalize(o + startF, 1, NULL, 1, &mean, &sd, len);
    if (!(sd > 1e-9f)) { free(o); return info; }
    float inv = 1.0f / sd;
    vDSP_vsmul(o, 1, &inv, o, 1, N);

    // tempo: autocorrelation over 55 ... 200 BPM, weighted by a one-octave
    // log-normal around 120 BPM (the usual prior; halves and doubles lose)
    int lagMin = MAX(2, (int)floor(60.0 / (200 * hopSec)));
    int lagMax = (int)ceil(60.0 / (55 * hopSec));
    if (lagMax * 2 >= len) { free(o); return info; }
    float ac0 = 0;
    vDSP_dotpr(o + startF, 1, o + startF, 1, &ac0, len);
    ac0 /= len;
    float *ac = calloc(lagMax + 2, sizeof(float)), *score = calloc(lagMax + 2, sizeof(float));
    int best = -1;
    for (int L = lagMin; L <= lagMax; L++) {
        float v = 0;
        vDSP_dotpr(o + startF, 1, o + startF + L, 1, &v, len - L);
        ac[L] = v / (len - L);
        double bpmL = 60.0 / (L * hopSec), oct = log2(bpmL / 120.0);
        score[L] = ac[L] * (float)exp(-0.5 * oct * oct);
        if (best < 0 || score[L] > score[best]) best = L;
    }
    double P = best;
    if (best > lagMin && best < lagMax) {
        double y0 = score[best - 1], y1 = score[best], y2 = score[best + 1], den = y0 - 2 * y1 + y2;
        if (den < 0) P = best + 0.5 * (y0 - y2) / den;
    }
    info.beatConfidence = ac0 > 0 ? MAX(0.0, MIN(1.0, ac[best] / ac0)) : 0;
    free(ac);
    free(score);
    info.bpm = 60.0 / (P * hopSec);
    if (info.beatConfidence < 0.05) { free(o); info.bpm = 0; return info; }

    // beats: dynamic programming, each beat = its onset strength plus the best
    // earlier beat, penalised by how far the gap is from one tempo period
    float *loc = calloc(N, sizeof(float));
    for (long t = 1; t + 1 < N; t++) loc[t] = 0.25f * o[t - 1] + 0.5f * o[t] + 0.25f * o[t + 1];
    free(o);
    int dmin = MAX(1, (int)lround(P / 2)), dmax = (int)lround(2 * P);
    double *tx = malloc((dmax - dmin + 1) * sizeof(double));
    for (int d = dmin; d <= dmax; d++) {
        double l = log(d / P);
        tx[d - dmin] = -100.0 * l * l;   // "tightness" 100, as in librosa
    }
    double *C = calloc(N, sizeof(double));
    long *back = malloc(N * sizeof(long));
    for (long t = 0; t < N; t++) back[t] = -1;
    for (long t = startF; t <= endF; t++) {
        double bv = 0;
        long arg = -1;
        for (int d = dmin; d <= dmax; d++) {
            long tau = t - d;
            if (tau < startF) break;
            double v = C[tau] + tx[d - dmin];
            if (v > bv) { bv = v; arg = tau; }
        }
        C[t] = loc[t] + bv;
        back[t] = arg;
    }
    free(tx);
    free(loc);
    long last = endF;
    for (long t = MAX(startF, endF - dmax); t <= endF; t++) if (C[t] > C[last]) last = t;
    NSMutableArray<NSNumber *> *beatFrames = [NSMutableArray array];
    for (long t = last; t >= 0; t = back[t]) [beatFrames insertObject:@(t) atIndex:0];
    free(C);
    free(back);
    if (beatFrames.count < 8) return info;

    // downbeats: of the four ways to group beats into bars, the one whose
    // beats carry the most low-end onset (kick on the one)
    double groupScore[4] = {0, 0, 0, 0};
    for (NSUInteger i = 0; i < beatFrames.count; i++) {
        long t = beatFrames[i].longValue;
        float m = 0;
        for (long u = MAX(0, t - 2); u <= MIN(N - 1, t + 2); u++) m = MAX(m, bassFlux[u]);
        groupScore[i % 4] += m;
    }
    int g = 0;
    for (int k = 1; k < 4; k++) if (groupScore[k] > groupScore[g]) g = k;
    NSMutableArray<NSNumber *> *bars = [NSMutableArray array];
    for (NSUInteger i = g; i < beatFrames.count; i += 4) {
        double t = beatFrames[i].longValue * hopSec;
        [bars addObject:@(round(t * 1000) / 1000)];
    }
    info.bars = bars;
    return info;
}

@end

#pragma mark - Apple

static NSArray<NSNumber *> *secondsFromMs(id arr) {
    NSMutableArray *out = [NSMutableArray array];
    if (![arr isKindOfClass:[NSArray class]]) return out;
    for (id v in arr) if ([v isKindOfClass:[NSNumber class]]) [out addObject:@([v doubleValue] / 1000.0)];
    return out;
}

static id at(id d, NSString *k) {
    return [d isKindOfClass:[NSDictionary class]] ? d[k] : nil;
}

DZSongInfo *DZSongInfoFromApple(NSDictionary *aa, double durationSeconds) {
    if (![aa isKindOfClass:[NSDictionary class]] || durationSeconds <= 0) return nil;
    DZSongInfo *i = [DZSongInfo new];
    i.source = @"apple";
    i.duration = durationSeconds;
    i.bars = secondsFromMs(at(at(aa, @"beats"), @"barsInMilliseconds"));
    i.bpm = num(at(at(aa, @"bpm"), @"main"));
    i.musicStart = num(at(at(at(aa, @"fades"), @"fadeIn"), @"startInMilliseconds")) / 1000.0;
    double fadeOut = num(at(at(at(aa, @"fades"), @"fadeOut"), @"startInMilliseconds")) / 1000.0;
    i.musicEnd = fadeOut > 0 && fadeOut <= durationSeconds ? fadeOut : durationSeconds;
    i.beatConfidence = i.bars.count ? 1 : 0;
    if (!i.bars.count && fadeOut <= 0) return nil;
    return i;
}

#pragma mark - merge and plan

DZSongInfo *DZSongInfoMerge(DZSongInfo *apple, DZSongInfo *own, NSString **note) {
    if (!apple && !own) return nil;
    if (!own) {
        if (note) *note = @"Apple";
        return apple;
    }
    if (!apple) {
        if (note) *note = @"Deezit";
        return own;
    }
    DZSongInfo *m = [own copyInfo];
    if (fabs(apple.duration - own.duration) <= 1.0) {
        m.source = @"apple+deezit";
        if (apple.bars.count) {
            m.bars = apple.bars;
            m.bpm = apple.bpm;
        }
        if (note) *note = apple.bars.count ? @"end: Deezit, bars: Apple" : @"Deezit (Apple has no bars)";
    } else if (note) {
        *note = [NSString stringWithFormat:@"Deezit (Apple's release is %.1f s, Deezer's %.1f s)", apple.duration, own.duration];
    }
    return m;
}

double DZPlanCrossfade(DZSongInfo *a, DZSongInfo *b, double durationA, NSString **why) {
    if (!a) return -1;
    double dur = durationA > 1 ? durationA : a.duration;
    if (dur < 20) return -1;
    double end = a.musicEnd > 0 && a.musicEnd <= dur ? a.musicEnd : dur;

    // how far into B its first downbeat is
    double lead = 0;
    if (b) {
        NSNumber *fb = [b firstBarFrom:MAX(0, b.musicStart - 0.05)];
        lead = fb ? fb.doubleValue : b.musicStart;
        lead = MAX(0, MIN(8, lead));
    }
    // B's downbeat lands on A's bar line where A winds down
    double landing = end;
    BOOL onBar = NO;
    for (NSNumber *bar in a.bars) {
        if (bar.doubleValue > end + 0.3) break;
        landing = bar.doubleValue;
        onBar = YES;
    }
    const double kMin = 1.0, kMax = 12.0;
    double d = dur - (landing - lead);
    if (d > kMax) {
        // a long outro: start later, still on a bar line
        onBar = NO;
        for (NSNumber *bar in a.bars) {
            double dd = dur - (bar.doubleValue - lead);
            if (dd <= kMax) {
                landing = bar.doubleValue;
                d = dd;
                onBar = YES;
                break;
            }
        }
    }
    double planned = MAX(kMin, MIN(kMax, d));
    if (why) {
        *why = [NSString stringWithFormat:@"A winds down at %.1f of %.1f s; %@; B's %@ at %.2f s%@",
                end, dur, onBar ? [NSString stringWithFormat:@"its bar line at %.2f s", landing] : @"no bar line there",
                b ? (b.bars.count ? @"first bar" : @"music") : @"(unknown) start", lead,
                planned != d ? [NSString stringWithFormat:@" (wanted %.1f s, kept within %.0f-%.0f s)", d, kMin, kMax] : @""];
    }
    return planned;
}

#pragma mark - storage

static NSURL *dirFor(NSString *source) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [[[support URLByAppendingPathComponent:@"Deezit"] URLByAppendingPathComponent:@"AutoMix"]
                  URLByAppendingPathComponent:source isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *safeName(NSString *isrc) {
    NSString *s = [[isrc componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]
                   componentsJoinedByString:@""];
    return s.length ? s.uppercaseString : @"unknown";
}

DZSongInfo *DZSongInfoLoad(NSString *isrc, NSString *source) {
    if (!isrc.length) return nil;
    NSURL *url = [dirFor(source) URLByAppendingPathComponent:[safeName(isrc) stringByAppendingPathExtension:@"plist"]];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    id d = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    return [DZSongInfo fromPlist:d];
}

void DZSongInfoSave(DZSongInfo *info, NSString *isrc) {
    if (!isrc.length || !info) return;
    NSString *source = [info.source isEqualToString:@"apple"] ? @"apple" : @"deezit";
    NSURL *url = [dirFor(source) URLByAppendingPathComponent:[safeName(isrc) stringByAppendingPathExtension:@"plist"]];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:[info plist] format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:nil];
    [data writeToURL:url atomically:YES];
}

NSUInteger DZSongInfoCount(NSString *source) {
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:dirFor(source).path error:nil].count;
}

BOOL DZAppleMissingRecently(NSString *isrc) {
    if (!isrc.length) return NO;
    NSString *path = [dirFor(@"apple-missing") URLByAppendingPathComponent:safeName(isrc)].path;
    NSDate *when = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    return when && -when.timeIntervalSinceNow < 7 * 24 * 3600;
}

void DZAppleMarkMissing(NSString *isrc) {
    if (!isrc.length) return;
    NSURL *url = [dirFor(@"apple-missing") URLByAppendingPathComponent:safeName(isrc)];
    [[NSData data] writeToURL:url atomically:YES];
}
