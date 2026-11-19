// Deezit - entry point.
//
// Injected into a decrypted Deezer IPA and sideloaded (no jailbreak). Logos
// runs with the "internal" generator, so every %hook here is plain ObjC
// runtime swizzling and works without Substrate/ElleKit.

#import <UIKit/UIKit.h>
#import "DZLog.h"
#import "DZDebugLog.h"
#import "DZPrefs.h"
#import "DZAudioHook.h"
#import "DZSettingsEntry.h"

#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif

void DZProbesInstall(void);     // DZProbes.x
void DZPlayerMenuInstall(void); // DZPlayerMenu.x

// Hooks live in their own files as %group blocks, each %init-ed by its
// install function: audio in DZAudioHook.x, UI probes in DZProbes.x, the
// player's ••• menu row in DZPlayerMenu.x.

%ctor {
    @autoreleasepool {
        DZDebugLogStart();
        NSBundle *b = NSBundle.mainBundle;
        DZLog("Deezit %s loaded into %@ %@ (%@), iOS %@", DEEZIT_VERSION, b.bundleIdentifier,
              [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [b objectForInfoDictionaryKey:@"CFBundleVersion"], UIDevice.currentDevice.systemVersion);

        DZPrefsBootstrap();
        DZAudioInstall();
        DZProbesInstall();
        DZPlayerMenuInstall();
        DZSettingsEntryInstall();
    }
}
