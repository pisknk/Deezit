#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Backing store for DZLog: last N lines in memory, the whole session in
// <container>/Library/Application Support/Deezit/deezit.log. The previous
// session's file is kept as deezit.prev.log so a crash can still be read
// after relaunching.

// Rotates the log files. Called once from the %ctor before the first DZLog.
void DZDebugLogStart(void);

// Current session as text (newest last), at most the in-memory ring.
NSString *DZDebugLogText(void);
NSURL *DZDebugLogFileURL(void);
// nil when there was no previous session.
NSURL * _Nullable DZDebugLogPreviousFileURL(void);
void DZDebugLogClear(void);

// Posted on the main queue whenever a line is added (the panel live-updates).
extern NSString *const DZDebugLogChangedNotification;

NS_ASSUME_NONNULL_END
