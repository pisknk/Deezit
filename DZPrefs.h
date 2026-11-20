#pragma once
#import <Foundation/Foundation.h>
#include "DZAudioParams.h"

NS_ASSUME_NONNULL_BEGIN

// Sideloaded = sandboxed: prefs live in the app container under this suite,
// not in /var/mobile/Library/Preferences like a jailbreak tweak.
extern NSString *const kDZPrefsSuite;
extern NSString *const DZPrefsChangedNotification;

extern NSString *const kDZEnabled;      // BOOL  master switch for the audio effect
extern NSString *const kDZSpeed;        // float 0.50 ... 1.50, pitch follows speed
extern NSString *const kDZReverbMix;    // float 0 ... 1 (wet amount)
extern NSString *const kDZReverbRoom;   // float 0 ... 1 (room size / decay)
extern NSString *const kDZReverbDamp;   // float 0 ... 1 (high-frequency damping)
extern NSString *const kDZPreset;       // NSString preset identifier, "custom" after manual edits
extern NSString *const kDZLockArtwork;  // BOOL  animated album covers on the lock screen (iOS 26+)
extern NSString *const kDZVocals;       // float 0 ... 1 vocal level ("Sing"): 1 = untouched, 0 = vocals removed
extern NSString *const kDZBackingVocals; // float 0 ... 1 how much of the side-panned (backing) vocals to keep
extern NSString *const kDZSingStrength;  // int 0 Gentle / 1 Normal / 2 Strong
extern NSString *const kDZAudioHook;    // BOOL  kill switch: NO = never touch Deezer's audio graph
                                        //       (read at launch, set from the debug panel)

extern const float kDZSpeedMin;
extern const float kDZSpeedMax;

void DZPrefsBootstrap(void);

BOOL DZPrefBool(NSString *key);
float DZPrefFloat(NSString *key);
NSString *DZPrefString(NSString *key);
void DZPrefSet(NSString *key, id _Nullable value);
// Writes several keys and posts a single change notification.
void DZPrefSetMany(NSDictionary<NSString *, id> *values);
void DZPrefsResetAudio(void);

NS_ASSUME_NONNULL_END
