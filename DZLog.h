#pragma once
#import <os/log.h>

// Filter in Console.app with: subsystem:com.pisknk.deezit
#define DZLog(fmt, ...) \
    os_log(dz_log_handle(), "[Deezit] " fmt, ##__VA_ARGS__)

static inline os_log_t dz_log_handle(void) {
    static os_log_t h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = os_log_create("com.pisknk.deezit", "tweak"); });
    return h;
}
