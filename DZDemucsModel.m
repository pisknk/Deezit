#import "DZDemucsModel.h"
#import <CoreML/CoreML.h>
#import <AppleArchive/AppleArchive.h>
#include <fcntl.h>
#include <os/proc.h>
#import "DZLog.h"

NSString *const DZDemucsChangedNotification = @"DZDemucsChangedNotification";

static NSString *const kDZRelease = @"https://github.com/pisknk/Deezit/releases/download/vocal-model-htdemucs-v1/";
static NSString *const kDZMeta = @"DeezitDemucs.json";

static NSObject *sLock;
static DZDemucsState sState;
static double sProgress;
static NSString *sError;
static NSURLSessionTask *sTask;
static NSTimer *sTimer;
static BOOL sBenchRunning;
static NSString *sBenchResult;

static NSURL *dir(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *d = [support URLByAppendingPathComponent:@"Deezit/models" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}
static NSURL *compiledURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.mlmodelc" isDirectory:YES]; }
static NSURL *packageURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.mlpackage" isDirectory:YES]; }
static NSURL *archiveURL(void) { return [dir() URLByAppendingPathComponent:@"DeezitDemucs.download.aar"]; }

static void recoverCrash(void);

static void notify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DZDemucsChangedNotification object:nil];
    });
}

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        sState = [NSFileManager.defaultManager fileExistsAtPath:compiledURL().path] ? DZDemucsReady : DZDemucsNotInstalled;
        recoverCrash();
    });
}

static void setState(DZDemucsState state, NSString *error) {
    @synchronized (sLock) { sState = state; sError = [error copy]; }
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

DZDemucsState DZDemucsGetState(void) { setup(); @synchronized (sLock) { return sState; } }
BOOL DZDemucsBenchmarkRunning(void) { setup(); @synchronized (sLock) { return sBenchRunning; } }
NSString *DZDemucsBenchmarkResult(void) { setup(); @synchronized (sLock) { return sBenchResult; } }

NSString *DZDemucsStatusText(void) {
    setup();
    @synchronized (sLock) {
        switch (sState) {
            case DZDemucsNotInstalled: return @"Not downloaded (about 85 MB)";
            case DZDemucsDownloading: return [NSString stringWithFormat:@"Downloading… %d%%", (int)lround(sProgress * 100)];
            case DZDemucsPreparing: return @"Preparing for this iPhone…";
            case DZDemucsReady: return [NSString stringWithFormat:@"Ready (%.0f MB)", folderSize(compiledURL()) / 1e6];
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

static void install(void) {
    setState(DZDemucsPreparing, nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (!extract(archiveURL(), packageURL())) {
            [NSFileManager.defaultManager removeItemAtURL:archiveURL() error:nil];
            setState(DZDemucsFailed, @"couldn't unpack the model archive");
            return;
        }
        [NSFileManager.defaultManager removeItemAtURL:archiveURL() error:nil];
        NSError *err = nil;
        NSURL *compiled = [MLModel compileModelAtURL:packageURL() error:&err];
        [NSFileManager.defaultManager removeItemAtURL:packageURL() error:nil];
        if (!compiled) { setState(DZDemucsFailed, [@"compile failed: " stringByAppendingString:err.localizedDescription ?: @"?"]); return; }
        [NSFileManager.defaultManager removeItemAtURL:compiledURL() error:nil];
        if (![NSFileManager.defaultManager moveItemAtURL:compiled toURL:compiledURL() error:&err]) {
            setState(DZDemucsFailed, err.localizedDescription ?: @"couldn't store the model");
            return;
        }
        DZLog("demucs: model installed (%.0f MB compiled)", folderSize(compiledURL()) / 1e6);
        setState(DZDemucsReady, nil);
    });
}

static void startProgress(NSURLSessionTask *task) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [sTimer invalidate];
        sTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            int64_t got = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive;
            @synchronized (sLock) { sProgress = total > 0 ? (double)got / (double)total : 0; }
            notify();
        }];
    });
}

static void stopProgress(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [sTimer invalidate]; sTimer = nil; });
}

void DZDemucsDownload(void) {
    setup();
    @synchronized (sLock) {
        if (sState == DZDemucsDownloading || sState == DZDemucsPreparing) return;
        sState = DZDemucsDownloading;
        sProgress = 0;
        sError = nil;
    }
    notify();
    // the release's JSON names the archive and its size
    NSURL *metaURL = [NSURL URLWithString:[kDZRelease stringByAppendingString:kDZMeta]];
    NSURLSessionDataTask *metaTask = [NSURLSession.sharedSession dataTaskWithURL:metaURL
                                                               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *meta = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *file = [meta isKindOfClass:[NSDictionary class]] ? meta[@"file"] : nil;
        if (![file isKindOfClass:[NSString class]] || ![file hasSuffix:@".aar"]) {
            if (err.code == NSURLErrorCancelled) { setState(DZDemucsNotInstalled, nil); return; }
            setState(DZDemucsFailed, err.localizedDescription ?: @"model not published yet");
            return;
        }
        DZLog("demucs: downloading %@ (%.0f MB)", file, [meta[@"bytes"] doubleValue] / 1e6);
        NSURL *url = [NSURL URLWithString:[kDZRelease stringByAppendingString:file]];
        NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
        NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithRequest:req
                                                                           completionHandler:^(NSURL *tmp, NSURLResponse *r, NSError *e) {
            stopProgress();
            @synchronized (sLock) { sTask = nil; }
            NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
            if (e.code == NSURLErrorCancelled) { setState(DZDemucsNotInstalled, nil); return; }
            [NSFileManager.defaultManager removeItemAtURL:archiveURL() error:nil];
            if (!tmp || e || status != 200 || ![NSFileManager.defaultManager moveItemAtURL:tmp toURL:archiveURL() error:nil]) {
                setState(DZDemucsFailed, e.localizedDescription ?: [NSString stringWithFormat:@"download failed (HTTP %ld)", (long)status]);
                return;
            }
            install();
        }];
        @synchronized (sLock) { sTask = task; }
        [task resume];
        startProgress(task);
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
    }
    [NSFileManager.defaultManager removeItemAtURL:compiledURL() error:nil];
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
    for (NSString *name in @[@"mix", @"spec"]) {
        MLFeatureDescription *d = model.modelDescription.inputDescriptionsByName[name];
        NSArray<NSNumber *> *shape = d.multiArrayConstraint.shape;
        if (!shape.count) { *error = [NSString stringWithFormat:@"model has no input \"%@\"", name]; return nil; }
        NSError *err = nil;
        MLMultiArray *a = [[MLMultiArray alloc] initWithShape:shape dataType:MLMultiArrayDataTypeFloat32 error:&err];
        if (!a) { *error = err.localizedDescription; return nil; }
        float *p = (float *)a.dataPointer;
        float scale = [name isEqualToString:@"mix"] ? 0.2f : 0.5f;
        uint32_t seed = 12345;
        for (NSInteger i = 0; i < a.count; i++) {
            seed = seed * 1664525u + 1013904223u;
            p[i] = ((float)(seed >> 8) / 16777216.0f * 2 - 1) * scale;
        }
        values[name] = [MLFeatureValue featureValueWithMultiArray:a];
    }
    NSError *err = nil;
    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:values error:&err];
    if (!provider) *error = err.localizedDescription;
    return provider;
}

// Share of the estimated compute on each unit, from Core ML's compute plan (iOS 17.4+).
static NSString *computePlanSummary(void) {
    if (@available(iOS 17.4, *)) {
        __block NSString *summary = @"compute plan unavailable";
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [MLComputePlan loadContentsOfURL:compiledURL() configuration:config()
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
            summary = [NSString stringWithFormat:@"compute: Neural Engine %.0f%%, CPU %.0f%%, GPU %.0f%% (ops %lu / %lu / %lu of %lu)",
                       ane / total * 100, cpu / total * 100, gpu / total * 100,
                       (unsigned long)aneOps, (unsigned long)cpuOps, (unsigned long)gpuOps, (unsigned long)ops];
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)));
        return summary;
    }
    return @"compute plan needs iOS 17.4";
}

// The benchmark can get Deezer killed (most likely iOS's memory limit: the
// whole 7.8 s window goes through the transformer at once). So each step is
// written to a small file before it starts, with the lowest free memory seen
// so far (sampled every 50 ms). If Deezer dies, the next launch turns that
// file into the result: which step, and how close to the limit it got.
static NSURL *crumbURL(void) { return [dir() URLByAppendingPathComponent:@"benchmark.running.txt"]; }
static NSURL *resultURL(void) { return [dir() URLByAppendingPathComponent:@"benchmark.result.txt"]; }

static NSString *sCrumbStep;
static NSString *sCrumbDone;         // results so far (survive a crash)
static double sMinFreeMB = -1;

static double freeMB(void) { return os_proc_available_memory() / 1048576.0; }

static void writeCrumb(void) {
    // called with sLock held
    NSString *text = [NSString stringWithFormat:@"%@\n%.0f\n%@", sCrumbStep ?: @"?", sMinFreeMB, sCrumbDone ?: @""];
    [[text dataUsingEncoding:NSUTF8StringEncoding] writeToURL:crumbURL() atomically:YES];
}

static void step(NSString *name) {
    double mb = freeMB();
    @synchronized (sLock) {
        sCrumbStep = name;
        if (sMinFreeMB < 0 || mb < sMinFreeMB) sMinFreeMB = mb;
        writeCrumb();
    }
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
    dispatch_source_set_event_handler(sampler, ^{
        double mb = freeMB();
        @synchronized (sLock) {
            if (sMinFreeMB < 0 || mb < sMinFreeMB - 5) { sMinFreeMB = mb; writeCrumb(); }
        }
    });
    dispatch_resume(sampler);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSString *> *lines = [NSMutableArray array];

        @autoreleasepool {
            NSError *err = nil;
            step(@"loading the model");
            CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
            MLModel *model = [MLModel modelWithContentsOfURL:compiledURL() configuration:config() error:&err];
            double loadS = CFAbsoluteTimeGetCurrent() - t0;
            NSString *problem = nil;
            MLDictionaryFeatureProvider *in = model ? inputs(model, &problem) : nil;
            if (!model || !in) {
                [lines addObject:[@"failed: " stringByAppendingString:problem ?: err.localizedDescription ?: @"couldn't load the model"]];
            } else {
                NSString *loaded = [NSString stringWithFormat:@"loaded in %.1f s", loadS];
                addDone(loaded);
                step(@"first run (includes Neural Engine compile)");
                t0 = CFAbsoluteTimeGetCurrent();
                BOOL ok;
                @autoreleasepool { ok = [model predictionFromFeatures:in error:&err] != nil; }
                double firstS = CFAbsoluteTimeGetCurrent() - t0;
                if (!ok) {
                    [lines addObject:[@"first run failed: " stringByAppendingString:err.localizedDescription ?: @"?"]];
                } else {
                    addDone([NSString stringWithFormat:@"first run %.1f s", firstS]);
                    step(@"timed runs");
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
                    // Live use would run one 7.8 s window per ~1 s of new audio,
                    // within Deezer's 3 s queue: under ~400 ms is comfortable.
                    NSString *verdict = median < 0 ? @"no timing" :
                        median <= 400 ? @"fast enough for live Sing" :
                        median <= 900 ? @"borderline for live Sing (would need bigger steps)" : @"too slow for live Sing";
                    NSString *timing = [NSString stringWithFormat:@"%.0f ms per 7.8 s window (median of %lu) - %@",
                                        median, (unsigned long)runs.count, verdict];
                    [lines insertObject:timing atIndex:0];
                    addDone(timing);
                    [lines addObject:[NSString stringWithFormat:@"%@, first run %.1f s (Neural Engine compile)", loaded, firstS]];
                }
            }
        }
        // Where each op would run. Last: on the iPhone 13 this step alone got Deezer
        // killed (it prepares the model for every unit to estimate costs).
        step(@"compute plan");
        NSString *plan = computePlanSummary();
        [lines addObject:plan];

        dispatch_source_cancel(sampler);
        double minFree;
        @synchronized (sLock) { minFree = sMinFreeMB; }
        [lines addObject:[NSString stringWithFormat:@"memory: %.0f MB free before, lowest %.0f MB during", startFree, minFree]];

        NSString *result = [lines componentsJoinedByString:@"\n"];
        DZLog("demucs: benchmark: %@", [result stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]);
        [[result dataUsingEncoding:NSUTF8StringEncoding] writeToURL:resultURL() atomically:YES];
        [NSFileManager.defaultManager removeItemAtURL:crumbURL() error:nil];
        @synchronized (sLock) { sBenchRunning = NO; sBenchResult = result; }
        notify();
    });
}
