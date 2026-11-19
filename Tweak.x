// Deezit - entry point.
//
// Injected into a decrypted Deezer IPA and sideloaded (no jailbreak). Logos
// runs with the "internal" generator, so every %hook here is plain ObjC
// runtime swizzling and works without Substrate/ElleKit.

#import <UIKit/UIKit.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAudioHook.h"
#import "DZSettingsEntry.h"

// Class-specific hooks (Now Playing button, Settings row, audio classes) go in
// %group blocks and are %init-ed only after objc_getClass() confirms the class
// exists, so a Deezer update that renames something degrades instead of crashing.

%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier;
        DZLog("loaded into %{public}@ %{public}@", bid,
              [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

        DZPrefsBootstrap();
        DZAudioInstall();
        DZSettingsEntryInstall();
    }
}
