#import "DZDemucsModel.h"
#import <CoreML/CoreML.h>
#import <AppleArchive/AppleArchive.h>
#include <fcntl.h>
#include <os/proc.h>
#import "DZLog.h"

NSString *const DZDemucsChangedNotification = @"DZDemucsChangedNotification";

// Model lab: candidate Sing models, benchmarked on the phone. One plain Core ML
// package (iOS 16 mlprogram, compiled on the phone) per model, as the release's
// JSON lists them. Now: the UVR MDX-Net vocal models (9482, Voc FT; MIT),
// published by .github/workflows/vocal-model-mdx.yml. Before: HT-Demucs
// (vocal-model-htdemucs-v4), which ran CPU-only on an iPhone 13 (1.1 s per
// 2.6 s window, 1.3 GB), too slow for live Sing.
static NSString *const kDZRelease = @"https://github.com/pisknk/Deezit/releases/download/vocal-model-mdx-v1/";
static NSString *const kDZMeta = @"DeezitMDX.json";
static NSString *const kDZFormat = @"aar-mlpackage-per-window";
static NSString *const kDZModelID = @"uvr-mdx-net";

static NSObject *sLock;
static DZDemucsState sState;
static double sProgress;
static NSString *sError;
static NSURLSessionTask *sTask;
static NSTimer *sTimer;
static BOOL sBenchRunning;
static NSString *sBenchResult;
static NSSet<NSString *> *sInstalledNames;                  // downloaded + compiled, by name
static NSMutableDictionary<NSString *, MLModel *> *sLoaded;  // loaded for playback
static NSMutableSet<NSString *> *sLoadingNames;

NSString *const kDZLabMDX = @"mdx9482";

static NSURL *dir(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *d = [support URLByAppendingPathComponent:@"Deezit/models" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static NSURL *windowURL(NSString *name) {
    return [dir() URLByAppendingPathComponent:[NSString stringWithFormat:@"DeezitDemucs-%@.mlmodelc", name] isDirectory:YES];
}
static NSURL *packageURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.download.mlpackage" isDirectory:YES]; }
static NSURL *archiveURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.download.aar"]; }
static NSURL *metaURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.json"]; }
static NSURL *metaPendingURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.download.json"]; }
static NSURL *resultURL(void);

static void recoverCrash(void);

static void notify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DZDemucsChangedNotification object:nil];
    });
}

// The windows a release's JSON lists (name, seconds, samples, frames, file),
// shortest first; empty if it isn't this format.
static NSArray<NSDictionary *> *windowsIn(NSData *data) {
    NSDictionary *meta = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![meta isKindOfClass:[NSDictionary class]] || ![meta[@"format"] isEqual:kDZFormat] || ![meta[@"model"] isEqual:kDZModelID]) return @[];
    NSArray *list = meta[@"functions"];
    if (![list isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSDictionary *f in list) {
        if ([f isKindOfClass:[NSDictionary class]] && [f[@"name"] isKindOfClass:[NSString class]]
            && [f[@"seconds"] isKindOfClass:[NSNumber class]] && [f[@"file"] isKindOfClass:[NSString class]]
            && [f[@"file"] hasSuffix:@".aar"])
            [out addObject:f];
    }
    // smallest first: shorter window, then fewer frequency bins
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult r = [a[@"seconds"] compare:b[@"seconds"]];
        if (r != NSOrderedSame) return r;
        return [@([a[@"bins"] doubleValue]) compare:@([b[@"bins"] doubleValue])];
    }];
    return out;
}

static NSArray<NSDictionary *> *functionsList(void) { return windowsIn([NSData dataWithContentsOfURL:metaURL()]); }

static BOOL installed(void) {
    NSArray<NSDictionary *> *list = functionsList();
    if (!list.count) return NO;
    for (NSDictionary *w in list)
        if (![NSFileManager.defaultManager fileExistsAtPath:windowURL(w[@"name"]).path]) return NO;
    return YES;
}

// Everything this file has ever stored (current windows and older layouts).
static void removeModels(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir().path error:nil] ?: @[]) {
        if ([f hasPrefix:@"DeezitDemucs"] && ([f hasSuffix:@".mlmodelc"] || [f hasSuffix:@".mlpackage"] || [f hasSuffix:@".aar"]))
            [fm removeItemAtURL:[dir() URLByAppendingPathComponent:f] error:nil];
    }
    [fm removeItemAtURL:metaURL() error:nil];
}

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        BOOL have = installed();
        BOOL leftovers = NO;
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir().path error:nil] ?: @[])
            if ([f hasPrefix:@"DeezitDemucs"]) leftovers = YES;
        if (!have && leftovers) {
            // an earlier lab model (HT-Demucs) or an unfinished download: removed
            removeModels();
            [NSFileManager.defaultManager removeItemAtURL:resultURL() error:nil];
        }
        sState = have ? DZDemucsReady : DZDemucsNotInstalled;
        sLoaded = [NSMutableDictionary dictionary];
        sLoadingNames = [NSMutableSet set];
        sInstalledNames = have ? [NSSet setWithArray:[functionsList() valueForKey:@"name"]] : [NSSet set];
        recoverCrash();
    });
}

static void setState(DZDemucsState state, NSString *error) {
    NSSet<NSString *> *names = state == DZDemucsReady ? [NSSet setWithArray:[functionsList() valueForKey:@"name"]] : [NSSet set];
    @synchronized (sLock) {
        sState = state;
        sError = [error copy];
        sInstalledNames = names;
        if (state != DZDemucsReady) [sLoaded removeAllObjects];
    }
    if (error) DZLog("demucs: %@", error);
    notify();
}

static unsigned long long folderSize(NSURL *url) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                     options:0 errorHandler:nil];
    for (NSURL *f in e) total += [[f resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey] unsignedLongLongValue];
    return total;
}

static unsigned long long installedSize(void) {
    unsigned long long total = 0;
    for (NSDictionary *w in functionsList()) total += folderSize(windowURL(w[@"name"]));
    return total;
}

DZDemucsState DZDemucsGetState(void) { setup(); @synchronized (sLock) { return sState; } }
BOOL DZDemucsBenchmarkRunning(void) { setup(); @synchronized (sLock) { return sBenchRunning; } }
NSString *DZDemucsBenchmarkResult(void) { setup(); @synchronized (sLock) { return sBenchResult; } }

NSString *DZDemucsStatusText(void) {
    setup();
    @synchronized (sLock) {
        switch (sState) {
            case DZDemucsNotInstalled: return @"Not downloaded (about 50 MB)";
            case DZDemucsDownloading: return [NSString stringWithFormat:@"Downloading… %d%%", (int)lround(sProgress * 100)];
            case DZDemucsPreparing: return [NSString stringWithFormat:@"Preparing for this iPhone… %d%%", (int)lround(sProgress * 100)];
            case DZDemucsReady: return [NSString stringWithFormat:@"Ready (%.0f MB)", installedSize() / 1e6];
            case DZDemucsFailed: return [@"Failed: " stringByAppendingString:sError ?: @"unknown error"];
        }
    }
    return @"";
}

#pragma mark - install

// Apple Archive (aa archive -d X.mlpackage) -> the package's contents under `dest`.
static BOOL extract(NSURL *archive, NSURL *dest) {
    [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
    [NSFileManager.defaultManager createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
    AAByteStream file = AAFileStreamOpenWithPath(archive.fileSystemRepresentation, O_RDONLY, 0644);
    if (!file) return NO;
    AAByteStream decompressed = AADecompressionInputStreamOpen(file, 0, 0);
    AAArchiveStream decoded = decompressed ? AADecodeArchiveInputStreamOpen(decompressed, NULL, NULL, 0, 0) : NULL;
    AAArchiveStream writer = decoded ? AAExtractArchiveOutputStreamOpen(dest.fileSystemRepresentation, NULL, NULL, 0, 0) : NULL;
    ssize_t entries = (decoded && writer) ? AAArchiveStreamProcess(decoded, writer, NULL, NULL, 0, 0) : -1;
    if (writer) AAArchiveStreamClose(writer);
    if (decoded) AAArchiveStreamClose(decoded);
    if (decompressed) AAByteStreamClose(decompressed);
    AAByteStreamClose(file);
    return entries >= 0;
}

// The downloaded archive -> windowURL(name), compiled on the phone (like the
// first HT-Demucs model and Spleeter, which load).
static NSString *install(NSString *name) {
    BOOL ok = extract(archiveURL(), packageURL());
    [NSFileManager.defaultManager removeItemAtURL:archiveURL() error:nil];
    if (!ok) { [NSFileManager.defaultManager removeItemAtURL:packageURL() error:nil]; return @"couldn't unpack the model archive"; }
    NSError *err = nil;
    NSURL *compiled = [MLModel compileModelAtURL:packageURL() error:&err];
    [NSFileManager.defaultManager removeItemAtURL:packageURL() error:nil];
    if (!compiled) return [@"compile failed: " stringByAppendingString:err.localizedDescription ?: @"?"];
    [NSFileManager.defaultManager removeItemAtURL:windowURL(name) error:nil];
    if (![NSFileManager.defaultManager moveItemAtURL:compiled toURL:windowURL(name) error:&err])
        return err.localizedDescription ?: @"couldn't store the model";
    return nil;
}

static void startProgress(NSURLSessionTask *task, NSUInteger index, NSUInteger count) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [sTimer invalidate];
        sTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            int64_t got = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive;
            double part = total > 0 ? (double)got / (double)total : 0;
            @synchronized (sLock) { sProgress = (index + part) / count; }
            notify();
        }];
    });
}

static void stopProgress(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [sTimer invalidate]; sTimer = nil; });
}

// Downloads and installs windows[index...], one after the other.
static void downloadWindow(NSArray<NSDictionary *> *windows, NSUInteger index) {
    if (index >= windows.count) {
        [NSFileManager.defaultManager removeItemAtURL:metaURL() error:nil];
        [NSFileManager.defaultManager moveItemAtURL:metaPendingURL() toURL:metaURL() error:nil];
        DZLog("demucs: model installed (%lu windows, %.0f MB compiled)", (unsigned long)windows.count, installedSize() / 1e6);
        setState(DZDemucsReady, nil);
        return;
    }
    NSDictionary *w = windows[index];
    @synchronized (sLock) { sState = DZDemucsDownloading; sProgress = (double)index / windows.count; }
    notify();
    DZLog("demucs: downloading %@ (%.0f MB)", w[@"file"], [w[@"bytes"] doubleValue] / 1e6);
    NSURL *url = [NSURL URLWithString:[kDZRelease stringByAppendingString:w[@"file"]]];
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithRequest:req
                                                                       completionHandler:^(NSURL *tmp, NSURLResponse *r, NSError *e) {
        stopProgress();
        @synchronized (sLock) { sTask = nil; }
        NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (e.code == NSURLErrorCancelled) { removeModels(); setState(DZDemucsNotInstalled, nil); return; }
        [NSFileManager.defaultManager removeItemAtURL:archiveURL() error:nil];
        if (!tmp || e || status != 200 || ![NSFileManager.defaultManager moveItemAtURL:tmp toURL:archiveURL() error:nil]) {
            removeModels();
            setState(DZDemucsFailed, e.localizedDescription ?: [NSString stringWithFormat:@"download failed (HTTP %ld)", (long)status]);
            return;
        }
        @synchronized (sLock) { sState = DZDemucsPreparing; sProgress = (index + 1.0) / windows.count; }
        notify();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *problem = install(w[@"name"]);
            if (problem) {
                removeModels();
                setState(DZDemucsFailed, [NSString stringWithFormat:@"%@: %@", w[@"name"], problem]);
                return;
            }
            downloadWindow(windows, index + 1);
        });
    }];
    @synchronized (sLock) { sTask = task; }
    [task resume];
    startProgress(task, index, windows.count);
}

void DZDemucsDownload(void) {
    setup();
    @synchronized (sLock) {
        if (sState == DZDemucsDownloading || sState == DZDemucsPreparing) return;
        sState = DZDemucsDownloading;
        sProgress = 0;
        sError = nil;
        sInstalledNames = [NSSet set];
        [sLoaded removeAllObjects];
    }
    notify();
    // the release's JSON lists the windows and their archives
    NSURL *remoteMeta = [NSURL URLWithString:[kDZRelease stringByAppendingString:kDZMeta]];
    NSURLRequest *metaReq = [NSURLRequest requestWithURL:remoteMeta cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    NSURLSessionDataTask *metaTask = [NSURLSession.sharedSession dataTaskWithRequest:metaReq
                                                               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        @synchronized (sLock) { sTask = nil; }
        NSArray<NSDictionary *> *windows = windowsIn(data);
        if (!windows.count) {
            if (err.code == NSURLErrorCancelled) { setState(DZDemucsNotInstalled, nil); return; }
            setState(DZDemucsFailed, err.localizedDescription ?: @"model not published yet");
            return;
        }
        removeModels();
        [NSFileManager.defaultManager removeItemAtURL:resultURL() error:nil];
        @synchronized (sLock) { sBenchResult = nil; }
        [data writeToURL:metaPendingURL() atomically:YES];
        downloadWindow(windows, 0);
    }];
    @synchronized (sLock) { sTask = metaTask; }
    [metaTask resume];
}

void DZDemucsCancel(void) {
    setup();
    NSURLSessionTask *task;
    @synchronized (sLock) { task = sTask; }
    [task cancel];
}

void DZDemucsDelete(void) {
    setup();
    @synchronized (sLock) {
        if (sState == DZDemucsDownloading || sState == DZDemucsPreparing || sBenchRunning) return;
        sBenchResult = nil;
        sInstalledNames = [NSSet set];
        [sLoaded removeAllObjects];
    }
    removeModels();
    [NSFileManager.defaultManager removeItemAtURL:resultURL() error:nil];
    DZLog("demucs: model deleted");
    setState(DZDemucsNotInstalled, nil);
}

#pragma mark - benchmark

static MLModelConfiguration *config(void) {
    MLModelConfiguration *cfg = [MLModelConfiguration new];
    // the same units Sing must use with the screen locked: no GPU
    if (@available(iOS 16.0, *)) cfg.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
    else cfg.computeUnits = MLComputeUnitsAll;
    return cfg;
}

// Inputs with realistic sizes and values (timing doesn't depend on content).
static MLDictionaryFeatureProvider *inputs(MLModel *model, NSString **error) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, MLFeatureDescription *> *all = model.modelDescription.inputDescriptionsByName;
    if (!all.count) { *error = @"model has no inputs"; return nil; }
    for (NSString *name in all) {
        MLMultiArrayConstraint *c = all[name].multiArrayConstraint;
        if (!c.shape.count) { *error = [NSString stringWithFormat:@"input \"%@\" isn't an array", name]; return nil; }
        BOOL half = NO;
        if (@available(iOS 16.0, *)) half = c.dataType == MLMultiArrayDataTypeFloat16;
        NSError *err = nil;
        MLMultiArray *a = nil;
        if (@available(iOS 16.0, *)) {
            a = [[MLMultiArray alloc] initWithShape:c.shape dataType:half ? MLMultiArrayDataTypeFloat16 : MLMultiArrayDataTypeFloat32 error:&err];
        } else {
            a = [[MLMultiArray alloc] initWithShape:c.shape dataType:MLMultiArrayDataTypeFloat32 error:&err];
        }
        if (!a) { *error = err.localizedDescription; return nil; }
        float scale = [name isEqualToString:@"mix"] ? 0.2f : 0.5f;
        uint32_t seed = 12345;
        for (NSInteger i = 0; i < a.count; i++) {
            seed = seed * 1664525u + 1013904223u;
            float v = ((float)(seed >> 8) / 16777216.0f * 2 - 1) * scale;
            if (half) ((__fp16 *)a.dataPointer)[i] = (__fp16)v;
            else ((float *)a.dataPointer)[i] = v;
        }
        values[name] = [MLFeatureValue featureValueWithMultiArray:a];
    }
    NSError *err = nil;
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:values error:&err];
    if (!provider) *error = err.localizedDescription;
    return provider;
}

// Share of the estimated compute on each unit, from Core ML's compute plan (iOS 17.4+).
static NSString *computePlanSummary(NSString *function) {
    if (@available(iOS 17.4, *)) {
        __block NSString *summary = @"compute plan unavailable";
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [MLComputePlan loadContentsOfURL:windowURL(function) configuration:config()
                       completionHandler:^(MLComputePlan *plan, NSError *err) {
            if (!plan) {
                summary = [@"compute plan failed: " stringByAppendingString:err.localizedDescription ?: @"?"];
                dispatch_semaphore_signal(done);
                return;
            }
            double ane = 0, cpu = 0, gpu = 0, unknown = 0;
            NSUInteger ops = 0, aneOps = 0, cpuOps = 0, gpuOps = 0;
            MLModelStructureProgram *program = plan.modelStructure.program;
            NSMutableArray<MLModelStructureProgramBlock *> *blocks = [NSMutableArray array];
            for (MLModelStructureProgramFunction *fn in program.functions.allValues) [blocks addObject:fn.block];
            while (blocks.count) {
                MLModelStructureProgramBlock *block = blocks.lastObject;
                [blocks removeLastObject];
                for (MLModelStructureProgramOperation *op in block.operations) {
                    [blocks addObjectsFromArray:op.blocks];
                    MLComputePlanDeviceUsage *usage = [plan computeDeviceUsageForMLProgramOperation:op];
                    if (!usage) continue;                         // constants etc.
                    double w = [plan estimatedCostOfMLProgramOperation:op].weight;
                    id device = usage.preferredComputeDevice;
                    ops++;
                    if ([device isKindOfClass:[MLNeuralEngineComputeDevice class]]) { ane += w; aneOps++; }
                    else if ([device isKindOfClass:[MLCPUComputeDevice class]]) { cpu += w; cpuOps++; }
                    else if ([device isKindOfClass:[MLGPUComputeDevice class]]) { gpu += w; gpuOps++; }
                    else unknown += w;
                }
            }
            double total = ane + cpu + gpu + unknown;
            if (total <= 0) total = 1;
            summary = [NSString stringWithFormat:@"compute (%@): Neural Engine %.0f%%, CPU %.0f%%, GPU %.0f%% (ops %lu / %lu / %lu of %lu)",
                       function, ane / total * 100, cpu / total * 100, gpu / total * 100,
                       (unsigned long)aneOps, (unsigned long)cpuOps, (unsigned long)gpuOps, (unsigned long)ops];
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
        return summary;
    }
    return @"compute plan needs iOS 17.4";
}

// The benchmark can get Deezer killed by iOS's memory limit (the 7.8 s window
// took ~2.2 GB to load on an iPhone 13). So each step is written to a small
// file before it starts, with the results so far and the lowest free memory
// seen (sampled every 10 ms). If Deezer dies, the next launch turns that file
// into the result. Windows run shortest first, and a longer one is skipped
// when the memory it would need (scaled from the previous one) isn't free.
static NSURL *crumbURL(void) { return [dir() URLByAppendingPathComponent:@"benchmark.running.txt"]; }
static NSURL *resultURL(void) { return [dir() URLByAppendingPathComponent:@"benchmark.result.txt"]; }

static NSString *sCrumbStep;
static NSString *sCrumbDone;         // results so far (survive a crash)
static double sMinFreeMB = -1;       // whole benchmark
static double sStepMinFreeMB = -1;   // current window

static double freeMB(void) { return os_proc_available_memory() / 1048576.0; }

static void writeCrumb(void) {
    // called with sLock held
    NSString *text = [NSString stringWithFormat:@"%@\n%.0f\n%@", sCrumbStep ?: @"?", sMinFreeMB, sCrumbDone ?: @""];
    [[text dataUsingEncoding:NSUTF8StringEncoding] writeToURL:crumbURL() atomically:YES];
}

static void noteFree(double mb, BOOL force) {
    @synchronized (sLock) {
        if (sStepMinFreeMB < 0 || mb < sStepMinFreeMB) sStepMinFreeMB = mb;
        if (force || sMinFreeMB < 0 || mb < sMinFreeMB - 5) {
            if (sMinFreeMB < 0 || mb < sMinFreeMB) sMinFreeMB = mb;
            writeCrumb();
        }
    }
}

static void step(NSString *name) {
    double mb = freeMB();
    @synchronized (sLock) { sCrumbStep = name; }
    noteFree(mb, YES);
    DZLog("demucs: benchmark step: %@ (%.0f MB free)", name, mb);
}

static void addDone(NSString *line) {
    @synchronized (sLock) {
        sCrumbDone = sCrumbDone.length ? [sCrumbDone stringByAppendingFormat:@"\n%@", line] : line;
        writeCrumb();
    }
}

// Called once from setup(): a crash during the last benchmark -> its result.
static void recoverCrash(void) {
    NSString *crumb = [NSString stringWithContentsOfURL:crumbURL() encoding:NSUTF8StringEncoding error:nil];
    if (crumb) {
        [NSFileManager.defaultManager removeItemAtURL:crumbURL() error:nil];
        NSArray<NSString *> *parts = [crumb componentsSeparatedByString:@"\n"];
        NSString *stepName = parts.count > 0 ? parts[0] : @"?";
        double minFree = parts.count > 1 ? parts[1].doubleValue : -1;
        NSString *done = parts.count > 2 ? [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@"\n"] : @"";
        NSString *result = [NSString stringWithFormat:@"Deezer closed during: %@ (lowest free memory seen %.0f MB; "
                            @"near 0 means iOS's memory limit; it's sampled every 10 ms, so a last spike can be missed)%@%@",
                            stepName, minFree, done.length ? @"\n" : @"", done];
        [[result dataUsingEncoding:NSUTF8StringEncoding] writeToURL:resultURL() atomically:YES];
        DZLog("demucs: last benchmark crashed: %@", [result stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]);
    }
    sBenchResult = [NSString stringWithContentsOfURL:resultURL() encoding:NSUTF8StringEncoding error:nil];
}

static NSUncaughtExceptionHandler *sPrevHandler;

static void exceptionNote(NSException *e) {
    BOOL running;
    @synchronized (sLock) { running = sBenchRunning; }
    if (running) addDone([NSString stringWithFormat:@"exception: %@: %@", e.name, e.reason]);
    if (sPrevHandler) sPrevHandler(e);
}

static void installExceptionNote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sPrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&exceptionNote);
    });
}

// One window: load, first run, 4 timed runs. Returns its result line, or nil
// with *failure set. *usedMB: the most memory it took (free before - lowest).
static NSString *benchWindow(NSDictionary *fn, double *usedMB, NSString **failure) {
    NSString *name = fn[@"name"];
    double seconds = [fn[@"seconds"] doubleValue];
    NSString *label = [fn[@"label"] isKindOfClass:[NSString class]] ? fn[@"label"] : [NSString stringWithFormat:@"%.1f s window", seconds];
    double before = freeMB();
    @synchronized (sLock) { sStepMinFreeMB = before; }
    // No pool around the whole function (an out-parameter set inside it would
    // be released with it); small pools instead, so the model and its inputs
    // are freed when this returns, before the next (bigger) window loads.
    NSError *err = nil;
    {
        step([label stringByAppendingString:@": loading"]);
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        MLModel *model;
        @autoreleasepool { model = [MLModel modelWithContentsOfURL:windowURL(name) configuration:config() error:&err]; }
        double loadS = CFAbsoluteTimeGetCurrent() - t0;
        double afterLoad = freeMB();
        NSString *problem = nil;
        MLDictionaryFeatureProvider *in;
        @autoreleasepool { in = model ? inputs(model, &problem) : nil; }
        if (!model || !in) {
            *failure = [NSString stringWithFormat:@"%@: %@", label, problem ?: err.localizedDescription ?: @"couldn't load"];
            return nil;
        }
        step([label stringByAppendingString:@": first run (includes Neural Engine compile)"]);
        t0 = CFAbsoluteTimeGetCurrent();
        BOOL ok;
        @autoreleasepool { ok = [model predictionFromFeatures:in error:&err] != nil; }
        double firstS = CFAbsoluteTimeGetCurrent() - t0;
        if (!ok) {
            *failure = [NSString stringWithFormat:@"%@: first run failed: %@", label, err.localizedDescription ?: @"?"];
            return nil;
        }
        step([label stringByAppendingString:@": timed runs"]);
        NSMutableArray<NSNumber *> *runs = [NSMutableArray array];
        for (int i = 0; i < 4; i++) {
            @autoreleasepool {
                t0 = CFAbsoluteTimeGetCurrent();
                if (![model predictionFromFeatures:in error:&err]) break;
                [runs addObject:@((CFAbsoluteTimeGetCurrent() - t0) * 1000)];
            }
        }
        [runs sortUsingSelector:@selector(compare:)];
        double median = runs.count ? runs[runs.count / 2].doubleValue : -1;
        double lowest;
        @synchronized (sLock) { lowest = sStepMinFreeMB; }
        *usedMB = before - lowest;
        // Live, each run moves the window on by step_fraction of it (half for
        // HT-Demucs, a quarter for MDX-Net's 5.9 s): that much new audio is the
        // time a run may take. Using under 40% of it leaves room for the rest.
        double step = [fn[@"step_fraction"] isKindOfClass:[NSNumber class]] ? [fn[@"step_fraction"] doubleValue] : 0.5;
        double share = median / (seconds * 1000 * step);
        NSString *verdict = median < 0 ? @"no timing" :
            share <= 0.4 ? @"fast enough for live Sing" : share <= 0.8 ? @"borderline for live Sing" : @"too slow for live Sing";
        return [NSString stringWithFormat:@"%@: %.0f ms per run (median of %lu), %.0f%% of the time live use allows - %@\n"
                @"   memory: %.0f MB to load, %.0f MB at most · load %.1f s, first run %.1f s",
                label, median, (unsigned long)runs.count, share * 100, verdict,
                before - afterLoad, *usedMB, loadS, firstS];
    }
}

void DZDemucsRunBenchmark(void) {
    setup();
    @synchronized (sLock) {
        if (sBenchRunning || sState != DZDemucsReady) return;
        sBenchRunning = YES;
        sBenchResult = nil;
        sCrumbDone = nil;
        sMinFreeMB = -1;
    }
    [NSFileManager.defaultManager removeItemAtURL:resultURL() error:nil];
    notify();
    double startFree = freeMB();
    DZLog("demucs: benchmark started (%.0f MB free)", startFree);
    addDone([NSString stringWithFormat:@"%.0f MB free at the start", startFree]);
    installExceptionNote();

    dispatch_source_t sampler = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(sampler, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sampler, ^{ noteFree(freeMB(), NO); });
    dispatch_resume(sampler);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSArray<NSDictionary *> *fns = functionsList();
        {
            if (!fns.count) [lines addObject:@"the model's window list is missing: delete and download it again"];
            double prevUsed = 0, prevSeconds = 0, prevBins = 1;
            NSMutableArray<NSString *> *ran = [NSMutableArray array];
            for (NSDictionary *fn in fns) {
                double seconds = [fn[@"seconds"] doubleValue];
                double bins = [fn[@"bins"] doubleValue] > 0 ? [fn[@"bins"] doubleValue] : 1;
                if (prevSeconds > 0) {
                    // memory grows with the frequency bins, and (attention) with the
                    // square of the window; keep 300 MB spare
                    double need = prevUsed * fmax(1, bins / prevBins) * (seconds / prevSeconds) * (seconds / prevSeconds);
                    double free = freeMB();
                    if (free < need + 300) {
                        NSString *name = [fn[@"label"] isKindOfClass:[NSString class]] ? fn[@"label"] : [NSString stringWithFormat:@"%.1f s window", seconds];
                        NSString *skip = [NSString stringWithFormat:@"%@: skipped, would need about %.0f MB and %.0f MB is free",
                                          name, need, free];
                        [lines addObject:skip];
                        addDone(skip);
                        break;
                    }
                }
                double used = 0;
                NSString *failure = nil;
                NSString *line = benchWindow(fn, &used, &failure);
                if (!line) { [lines addObject:failure]; addDone(failure); break; }
                [lines addObject:line];
                addDone(line);
                prevUsed = used;
                prevSeconds = seconds;
                prevBins = bins;
                [ran addObject:fn[@"name"]];
            }
            // Where each op would run, for every model that ran. Last: with
            // HT-Demucs' 7.8 s model this step alone got Deezer killed.
            for (NSString *name in ran) {
                step([@"compute plan " stringByAppendingString:name]);
                [lines addObject:computePlanSummary(name)];
            }
        }
        dispatch_source_cancel(sampler);
        double minFree;
        @synchronized (sLock) { minFree = sMinFreeMB; }
        [lines addObject:[NSString stringWithFormat:@"memory: %.0f MB free at the start, lowest %.0f MB", startFree, minFree]];

        NSString *result = [lines componentsJoinedByString:@"\n"];
        DZLog("demucs: benchmark: %@", [result stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]);
        [[result dataUsingEncoding:NSUTF8StringEncoding] writeToURL:resultURL() atomically:YES];
        [NSFileManager.defaultManager removeItemAtURL:crumbURL() error:nil];
        @synchronized (sLock) { sBenchRunning = NO; sBenchResult = result; }
        notify();
    });
}

#pragma mark - playback

BOOL DZLabModelInstalled(NSString *name) {
    setup();
    @synchronized (sLock) { return [sInstalledNames containsObject:name]; }
}

MLModel *DZLabModelGet(NSString *name) {
    setup();
    @synchronized (sLock) {
        MLModel *m = sLoaded[name];
        if (m || ![sInstalledNames containsObject:name] || [sLoadingNames containsObject:name]) return m;
        [sLoadingNames addObject:name];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        MLModel *model = [MLModel modelWithContentsOfURL:windowURL(name) configuration:config() error:&err];
        @synchronized (sLock) {
            [sLoadingNames removeObject:name];
            if (model && [sInstalledNames containsObject:name]) sLoaded[name] = model;
        }
        DZLog("lab: %@ %@", name, model ? @"loaded for playback" : [@"failed to load: " stringByAppendingString:err.localizedDescription ?: @"?"]);
        notify();
    });
    return nil;
}
