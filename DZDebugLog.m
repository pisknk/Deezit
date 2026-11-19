#import "DZDebugLog.h"
#import "DZLog.h"
#import <os/log.h>

NSString *const DZDebugLogChangedNotification = @"DZDebugLogChangedNotification";

static const NSUInteger kDZRingMax = 600;

static dispatch_queue_t sQueue;          // serialises ring + file writes
static NSMutableArray<NSString *> *sRing;
static NSURL *sFileURL;
static NSURL *sPrevURL;
static NSDateFormatter *sStamp;
static BOOL sNotifyPending;              // coalesce panel refreshes

static os_log_t logHandle(void) {
    static os_log_t h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = os_log_create("com.pisknk.deezit", "tweak"); });
    return h;
}

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sQueue = dispatch_queue_create("com.pisknk.deezit.log", DISPATCH_QUEUE_SERIAL);
        sRing = [NSMutableArray array];
        sStamp = [NSDateFormatter new];
        sStamp.dateFormat = @"HH:mm:ss.SSS";
        sStamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *dir = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
                         URLByAppendingPathComponent:@"Deezit" isDirectory:YES];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
        sFileURL = [dir URLByAppendingPathComponent:@"deezit.log"];
        sPrevURL = [dir URLByAppendingPathComponent:@"deezit.prev.log"];
    });
}

void DZDebugLogStart(void) {
    setup();
    dispatch_sync(sQueue, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:sFileURL.path]) {
            [fm removeItemAtURL:sPrevURL error:nil];
            [fm moveItemAtURL:sFileURL toURL:sPrevURL error:nil];
        }
        [NSData.data writeToURL:sFileURL atomically:NO];
    });
}

static void scheduleNotify(void) {
    // called on sQueue
    if (sNotifyPending) return;
    sNotifyPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dispatch_async(sQueue, ^{ sNotifyPending = NO; });
        [[NSNotificationCenter defaultCenter] postNotificationName:DZDebugLogChangedNotification object:nil];
    });
}

void DZLogLine(NSString *line) {
    setup();
    os_log(logHandle(), "[Deezit] %{public}@", line);
    NSDate *now = [NSDate date];
    BOOL main = [NSThread isMainThread];
    dispatch_async(sQueue, ^{
        NSString *full = [NSString stringWithFormat:@"%@ %@%@\n", [sStamp stringFromDate:now], main ? @"" : @"[bg] ", line];
        [sRing addObject:full];
        if (sRing.count > kDZRingMax) [sRing removeObjectsInRange:NSMakeRange(0, sRing.count - kDZRingMax)];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:sFileURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [[full dataUsingEncoding:NSUTF8StringEncoding] writeToURL:sFileURL atomically:NO];
        }
        scheduleNotify();
    });
}

NSString *DZDebugLogText(void) {
    setup();
    __block NSString *text;
    dispatch_sync(sQueue, ^{ text = [sRing componentsJoinedByString:@""]; });
    return text;
}

NSURL *DZDebugLogFileURL(void) { setup(); return sFileURL; }

NSURL *DZDebugLogPreviousFileURL(void) {
    setup();
    return [NSFileManager.defaultManager fileExistsAtPath:sPrevURL.path] ? sPrevURL : nil;
}

void DZDebugLogClear(void) {
    setup();
    dispatch_async(sQueue, ^{
        [sRing removeAllObjects];
        [NSData.data writeToURL:sFileURL atomically:NO];
        scheduleNotify();
    });
}
