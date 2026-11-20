#pragma once
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

NS_ASSUME_NONNULL_BEGIN

// The "Sing" vocal-separation model (Spleeter 2-stems, Deezer Research, MIT),
// converted to Core ML by .github/workflows/vocal-model.yml and published as a
// release asset. Not bundled in the dylib: Settings → Sing → Download fetches
// it once, compiles it on the device and keeps it in
// Library/Application Support/Deezit/models.
//
// Model contract (tools/vocal_model/convert.py):
//   input  "magnitude"  float32 [1, 2, 128, 1024]  |STFT| (N 4096, hop 1024), L/R, time, bins 0..1023
//   output "vocal_mask" float32 [1, 2, 128, 1024]  0...1, share of each bin that is vocals

typedef NS_ENUM(NSInteger, DZVocalModelState) {
    DZVocalModelNotInstalled,
    DZVocalModelDownloading,
    DZVocalModelCompiling,
    DZVocalModelReady,
    DZVocalModelFailed,
};

extern NSString *const DZVocalModelChangedNotification;   // posted on the main queue

DZVocalModelState DZVocalModelGetState(void);
double DZVocalModelProgress(void);          // 0...1 while downloading
NSString *DZVocalModelStatusText(void);     // for the settings row
NSString *DZVocalModelDownloadSize(void);   // "about 40 MB"

void DZVocalModelDownload(void);
void DZVocalModelCancel(void);
void DZVocalModelDelete(void);

// The loaded model, or nil (not installed / still loading). Loads it in the
// background on first call once installed; safe from any thread.
MLModel * _Nullable DZVocalModelGet(void);

NS_ASSUME_NONNULL_END
