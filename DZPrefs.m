#import "DZPrefs.h"
#import "DZLog.h"
#include <stdatomic.h>

NSString *const kDZPrefsSuite = @"com.pisknk.deezit";
NSString *const DZPrefsChangedNotification = @"DZPrefsChangedNotification";

NSString *const kDZEnabled = @"enabled";
NSString *const kDZSpeed = @"speed";
NSString *const kDZReverbMix = @"reverbMix";
NSString *const kDZReverbRoom = @"reverbRoom";
NSString *const kDZReverbDamp = @"reverbDamp";
NSString *const kDZPreset = @"preset";
NSString *const kDZAudioHook = @"audioHook";
NSString *const kDZLockArtwork = @"lockArtwork";
NSString *const kDZVocals = @"vocals";
NSString *const kDZBackingVocals = @"backingVocals";
NSString *const kDZSingStrength = @"singStrength";

const float kDZSpeedMin = 0.50f;
const float kDZSpeedMax = 1.50f;

static NSUserDefaults *sDefaults;

// Mirrors of the audio keys for the render thread.
static _Atomic bool  sEnabled;
static _Atomic float sSpeed;
static _Atomic float sReverbMix;
static _Atomic float sReverbRoom;
static _Atomic float sReverbDamp;
static _Atomic float sVocalCut;
static _Atomic float sBackingKeep;
static _Atomic int sSingStrength = 1;

static NSDictionary *defaultValues(void) {
    return @{
        kDZEnabled: @NO,
        kDZSpeed: @1.0f,
        kDZReverbMix: @0.0f,
        kDZReverbRoom: @0.75f,
        kDZReverbDamp: @0.4f,
        kDZPreset: @"off",
        kDZAudioHook: @YES,
        kDZLockArtwork: @YES,
        kDZVocals: @1.0f,
        kDZBackingVocals: @0.0f,
        kDZSingStrength: @1,
    };
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void refreshAtomics(void) {
    atomic_store(&sEnabled, (bool)[sDefaults boolForKey:kDZEnabled]);
    atomic_store(&sSpeed, clampf([sDefaults floatForKey:kDZSpeed], kDZSpeedMin, kDZSpeedMax));
    atomic_store(&sReverbMix, clampf([sDefaults floatForKey:kDZReverbMix], 0, 1));
    atomic_store(&sReverbRoom, clampf([sDefaults floatForKey:kDZReverbRoom], 0, 1));
    atomic_store(&sReverbDamp, clampf([sDefaults floatForKey:kDZReverbDamp], 0, 1));
    atomic_store(&sVocalCut, 1.0f - clampf([sDefaults floatForKey:kDZVocals], 0, 1));
    atomic_store(&sBackingKeep, clampf([sDefaults floatForKey:kDZBackingVocals], 0, 1));
    NSInteger strength = [sDefaults integerForKey:kDZSingStrength];
    atomic_store(&sSingStrength, (int)(strength < 0 ? 0 : strength > 2 ? 2 : strength));
}

static void postChanged(void) {
    refreshAtomics();
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DZPrefsChangedNotification object:nil];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

void DZPrefsBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDefaults = [[NSUserDefaults alloc] initWithSuiteName:kDZPrefsSuite];
        [sDefaults registerDefaults:defaultValues()];
        refreshAtomics();
        DZLog("prefs loaded: enabled=%d speed=%.2f mix=%.2f audioHook=%d",
              [sDefaults boolForKey:kDZEnabled], [sDefaults floatForKey:kDZSpeed],
              [sDefaults floatForKey:kDZReverbMix], [sDefaults boolForKey:kDZAudioHook]);
    });
}

BOOL DZPrefBool(NSString *key) { DZPrefsBootstrap(); return [sDefaults boolForKey:key]; }
float DZPrefFloat(NSString *key) { DZPrefsBootstrap(); return [sDefaults floatForKey:key]; }
NSString *DZPrefString(NSString *key) { DZPrefsBootstrap(); return [sDefaults stringForKey:key] ?: @""; }

void DZPrefSet(NSString *key, id value) {
    DZPrefsBootstrap();
    if (value) [sDefaults setObject:value forKey:key];
    else [sDefaults removeObjectForKey:key];
    postChanged();
}

void DZPrefSetMany(NSDictionary<NSString *, id> *values) {
    DZPrefsBootstrap();
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if (v == [NSNull null]) [sDefaults removeObjectForKey:k];
        else [sDefaults setObject:v forKey:k];
    }];
    postChanged();
}

void DZPrefsResetAudio(void) {
    DZPrefsBootstrap();
    for (NSString *k in @[kDZSpeed, kDZReverbMix, kDZReverbRoom, kDZReverbDamp, kDZPreset, kDZVocals, kDZBackingVocals, kDZSingStrength]) {
        [sDefaults removeObjectForKey:k];
    }
    postChanged();
}

DZAudioParams DZPrefsAudioParams(void) {
    DZAudioParams p;
    p.enabled = atomic_load_explicit(&sEnabled, memory_order_relaxed);
    p.speed = atomic_load_explicit(&sSpeed, memory_order_relaxed);
    p.reverbMix = atomic_load_explicit(&sReverbMix, memory_order_relaxed);
    p.reverbRoom = atomic_load_explicit(&sReverbRoom, memory_order_relaxed);
    p.reverbDamp = atomic_load_explicit(&sReverbDamp, memory_order_relaxed);
    p.vocalCut = atomic_load_explicit(&sVocalCut, memory_order_relaxed);
    p.backingKeep = atomic_load_explicit(&sBackingKeep, memory_order_relaxed);
    p.singStrength = atomic_load_explicit(&sSingStrength, memory_order_relaxed);
    if (p.speed <= 0) p.speed = 1.0f; // never bootstrapped yet
    return p;
}
