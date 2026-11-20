#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Experimental second Sing model: the vocals model of Demucs htdemucs_ft
// (Meta, MIT), converted by .github/workflows/vocal-model-htdemucs.yml and
// published on the `vocal-model-htdemucs-v1` release as an Apple Archive of
// the .mlpackage. For now it is only benchmarked on the phone (does it keep
// up in real time, and does it stay on the Neural Engine so it works with the
// screen locked); playback still uses Spleeter.

typedef NS_ENUM(NSInteger, DZDemucsState) {
    DZDemucsNotInstalled,
    DZDemucsDownloading,
    DZDemucsPreparing,
    DZDemucsReady,
    DZDemucsFailed,
};

extern NSString *const DZDemucsChangedNotification;   // posted on the main queue

DZDemucsState DZDemucsGetState(void);
NSString *DZDemucsStatusText(void);
BOOL DZDemucsBenchmarkRunning(void);
NSString * _Nullable DZDemucsBenchmarkResult(void);    // last result, multi-line

void DZDemucsDownload(void);
void DZDemucsCancel(void);
void DZDemucsDelete(void);
void DZDemucsRunBenchmark(void);

NS_ASSUME_NONNULL_END
