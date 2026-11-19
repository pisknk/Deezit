#pragma once
#import <UIKit/UIKit.h>

// The in-app Deezit settings page (effect switch, presets, speed, reverb).
@interface DZSettingsViewController : UITableViewController
// Wrapped in a navigation controller with a Done button, ready to present.
+ (UIViewController *)presentableController;
// The same page as "Playback Controls": a half-height sheet with a grabber
// (expandable to full height), opened from the player's ••• menu.
+ (UIViewController *)playbackControlsController;
@end
