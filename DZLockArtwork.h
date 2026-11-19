#pragma once
#import <Foundation/Foundation.h>

// Animated album covers on the lock screen (iOS 26+), see DZLockArtwork.x.
void DZLockArtworkInstall(void);
// One line for the debug panel.
NSString *DZLockArtworkStatus(void);
