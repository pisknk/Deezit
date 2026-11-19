#pragma once
#import <Foundation/Foundation.h>

// DZLog("fmt %@ %d", obj, n) - NSString-style format (no os_log privacy
// annotations). Every line goes to:
//   - os_log, subsystem com.pisknk.deezit (Console.app, if you have a Mac)
//   - an in-memory ring + a log file in the app container, which the in-app
//     debug panel shows and shares (three-finger double tap), so a sideloaded
//     install on a phone with no Mac nearby can still be debugged.
// Never call it from a realtime audio render callback.
#define DZLog(fmt, ...) DZLogLine([NSString stringWithFormat:@fmt, ##__VA_ARGS__])

#ifdef __cplusplus
extern "C" {
#endif
void DZLogLine(NSString *line);
#ifdef __cplusplus
}
#endif
