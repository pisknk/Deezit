#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The Deezit debug panel (three-finger double tap anywhere in Deezer):
// status summary + live log, with share / copy / clear, a shortcut to the
// settings page and the audio-hook kill switch.
@interface DZDebugViewController : UIViewController
+ (UIViewController *)presentableController;
@end

// Small non-interactive banner at the top of the key window.
void DZToast(NSString *message);

NS_ASSUME_NONNULL_END
