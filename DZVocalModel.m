#import "DZVocalModel.h"
#import "DZLog.h"

NSString *const DZVocalModelChangedNotification = @"DZVocalModelChangedNotification";

// Published by .github/workflows/vocal-model.yml
static NSString *const kDZModelURL = @"https://github.com/pisknk/Deezit/releases/download/vocal-model-v1/DeezitVocals.mlmodel";

static NSObject *sLock;
static DZVocalModelState sState;
static double sProgress;
static NSString *sError;
static NSURLSessionDownloadTask *sTask;
static NSTimer *sProgressTimer;
static MLModel *sModel;
static BOOL sLoading;

static NSURL *modelsDir(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"Deezit/models" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSURL *compiledURL(void) {
    return [modelsDir() URLByAppendingPathComponent:@"DeezitVocals.mlmodelc" isDirectory:YES];
}

static void notify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DZVocalModelChangedNotification object:nil];
    });
}

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        sState = [NSFileManager.defaultManager fileExistsAtPath:compiledURL().path] ? DZVocalModelReady : DZVocalModelNotInstalled;
    });
}

static unsigned long long folderSize(NSURL *url) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLFileSizeKey]
                                                                     options:0 errorHandler:nil];
    for (NSURL *f in e) total += [[f resourceValuesForKeys:@[NSURLFileSizeKey] error:nil][NSURLFileSizeKey] unsignedLongLongValue];
    return total;
}

// The model must take and give what the separator expects.
static NSString *checkContract(MLModel *model) {
    MLFeatureDescription *in = model.modelDescription.inputDescriptionsByName[@"magnitude"];
    MLFeatureDescription *out = model.modelDescription.outputDescriptionsByName[@"vocal_mask"];
    if (!in || !out) return @"model has the wrong inputs / outputs";
    NSArray<NSNumber *> *shape = in.multiArrayConstraint.shape;
    if (shape.count != 4 || shape[1].intValue != 2 || shape[2].intValue != 128 || shape[3].intValue != 1024) {
        return [NSString stringWithFormat:@"unexpected input shape %@", shape];
    }
    return nil;
}

static MLModel *loadCompiled(NSString **error) {
    MLModelConfiguration *cfg = [MLModelConfiguration new];
    cfg.computeUnits = MLComputeUnitsAll;   // Neural Engine when it can
    NSError *err = nil;
    MLModel *model = [MLModel modelWithContentsOfURL:compiledURL() configuration:cfg error:&err];
    if (!model) { if (error) *error = err.localizedDescription ?: @"couldn't load"; return nil; }
    NSString *bad = checkContract(model);
    if (bad) { if (error) *error = bad; return nil; }
    // warm-up: the first prediction compiles for the Neural Engine and can take
    // seconds; do it here, before anyone relies on the model being fast
    MLMultiArray *zeros = [[MLMultiArray alloc] initWithShape:@[@1, @2, @128, @1024] dataType:MLMultiArrayDataTypeFloat32 error:&err];
    if (zeros) {
        memset(zeros.dataPointer, 0, sizeof(float) * 2 * 128 * 1024);
        MLDictionaryFeatureProvider *in = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{ @"magnitude": [MLFeatureValue featureValueWithMultiArray:zeros] } error:&err];
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        id<MLFeatureProvider> out = in ? [model predictionFromFeatures:in error:&err] : nil;
        if (!out) { if (error) *error = err.localizedDescription ?: @"test run failed"; return nil; }
        DZLog("sing: model warm-up run took %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000);
    }
    return model;
}

DZVocalModelState DZVocalModelGetState(void) { setup(); @synchronized (sLock) { return sState; } }
double DZVocalModelProgress(void) { setup(); @synchronized (sLock) { return sProgress; } }
NSString *DZVocalModelDownloadSize(void) { return @"about 40 MB"; }

NSString *DZVocalModelStatusText(void) {
    setup();
    @synchronized (sLock) {
        switch (sState) {
            case DZVocalModelNotInstalled: return [NSString stringWithFormat:@"Not downloaded (%@)", DZVocalModelDownloadSize()];
            case DZVocalModelDownloading: return [NSString stringWithFormat:@"Downloading… %d%%", (int)lround(sProgress * 100)];
            case DZVocalModelCompiling: return @"Preparing for this iPhone…";
            case DZVocalModelReady: {
                double mb = folderSize(compiledURL()) / 1e6;
                return [NSString stringWithFormat:@"Ready (%.0f MB)", mb];
            }
            case DZVocalModelFailed: return [@"Failed: " stringByAppendingString:sError ?: @"unknown error"];
        }
    }
    return @"";
}

static void setState(DZVocalModelState state, NSString *error) {
    @synchronized (sLock) {
        sState = state;
        sError = [error copy];
    }
    notify();
}

static void stopProgressTimer(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [sProgressTimer invalidate];
        sProgressTimer = nil;
    });
}

// Downloaded .mlmodel -> compiled .mlmodelc in place of any old one -> checked by loading it.
static void install(NSURL *downloaded) {
    setState(DZVocalModelCompiling, nil);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        NSURL *compiled = [MLModel compileModelAtURL:downloaded error:&err];
        [NSFileManager.defaultManager removeItemAtURL:downloaded error:nil];
        if (!compiled) {
            DZLog("sing: compiling the model failed: %@", err.localizedDescription);
            setState(DZVocalModelFailed, err.localizedDescription ?: @"compile failed");
            return;
        }
        NSURL *dest = compiledURL();
        [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
        if (![NSFileManager.defaultManager moveItemAtURL:compiled toURL:dest error:&err]) {
            setState(DZVocalModelFailed, err.localizedDescription ?: @"couldn't store the model");
            return;
        }
        NSString *loadError = nil;
        MLModel *model = loadCompiled(&loadError);
        if (!model) {
            [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
            DZLog("sing: downloaded model rejected: %@", loadError);
            setState(DZVocalModelFailed, loadError);
            return;
        }
        @synchronized (sLock) { sModel = model; }
        DZLog("sing: vocal model installed (%.0f MB)", folderSize(dest) / 1e6);
        setState(DZVocalModelReady, nil);
    });
}

void DZVocalModelDownload(void) {
    setup();
    @synchronized (sLock) {
        if (sState == DZVocalModelDownloading || sState == DZVocalModelCompiling) return;
        sState = DZVocalModelDownloading;
        sProgress = 0;
        sError = nil;
    }
    notify();
    DZLog("sing: downloading the vocal model from %@", kDZModelURL);
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:kDZModelURL]
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithRequest:req
                                                                       completionHandler:^(NSURL *tmp, NSURLResponse *resp, NSError *err) {
        stopProgressTimer();
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        @synchronized (sLock) { sTask = nil; }
        if (err.code == NSURLErrorCancelled) { setState(DZVocalModelNotInstalled, nil); return; }
        if (!tmp || err || status != 200) {
            NSString *why = err.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];
            DZLog("sing: model download failed: %@", why);
            setState(DZVocalModelFailed, why);
            return;
        }
        // keep it past this handler, with the extension compileModelAtURL: expects
        NSURL *kept = [modelsDir() URLByAppendingPathComponent:@"DeezitVocals.download.mlmodel"];
        [NSFileManager.defaultManager removeItemAtURL:kept error:nil];
        if (![NSFileManager.defaultManager moveItemAtURL:tmp toURL:kept error:nil]) {
            setState(DZVocalModelFailed, @"couldn't keep the download");
            return;
        }
        install(kept);
    }];
    @synchronized (sLock) { sTask = task; }
    [task resume];
    dispatch_async(dispatch_get_main_queue(), ^{
        [sProgressTimer invalidate];
        sProgressTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
            int64_t got = task.countOfBytesReceived, total = task.countOfBytesExpectedToReceive;
            @synchronized (sLock) { sProgress = total > 0 ? (double)got / (double)total : 0; }
            notify();
        }];
    });
}

void DZVocalModelCancel(void) {
    setup();
    NSURLSessionDownloadTask *task;
    @synchronized (sLock) { task = sTask; }
    [task cancel];
}

void DZVocalModelDelete(void) {
    setup();
    @synchronized (sLock) {
        if (sState == DZVocalModelDownloading || sState == DZVocalModelCompiling) return;
        sModel = nil;
    }
    [NSFileManager.defaultManager removeItemAtURL:compiledURL() error:nil];
    DZLog("sing: vocal model deleted");
    setState(DZVocalModelNotInstalled, nil);
}

MLModel *DZVocalModelGet(void) {
    setup();
    @synchronized (sLock) {
        if (sModel || sState != DZVocalModelReady || sLoading) return sModel;
        sLoading = YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        MLModel *model = loadCompiled(&error);
        @synchronized (sLock) {
            sModel = model;
            sLoading = NO;
            if (!model) { sState = DZVocalModelFailed; sError = error; }
        }
        DZLog("sing: vocal model %@", model ? @"loaded" : [@"failed to load: " stringByAppendingString:error ?: @"?"]);
        notify();
    });
    return nil;
}
