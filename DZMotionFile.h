#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The lock screen's animated artwork wants a local video file. Apple Music's
// motion covers are HLS: this picks the variant closest to ~1100 px wide (HEVC
// first), downloads it as one MP4 (its segments are byte ranges of a single
// fragmented MP4, or are concatenated if not) into
// Library/Caches/Deezit/motion/<name>.mp4, and keeps the folder under 150 MB.
// Concurrent requests for the same name share one download.
void DZMotionFile(NSURL *master, NSString *name, void (^done)(NSURL * _Nullable file, NSString *note));

// First frame of the clip, for the still the lock screen shows before / around it.
void DZMotionPreview(NSURL *file, CGSize size, void (^done)(UIImage * _Nullable image));

NS_ASSUME_NONNULL_END
