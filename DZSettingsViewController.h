#pragma once
#import <UIKit/UIKit.h>

// The in-app Deezit settings page (effect switch, presets, speed, reverb).
@interface DZSettingsViewController : UITableViewController
// Wrapped in a navigation controller with a Done button, ready to present.
+ (UIViewController *)presentableController;
// The same page as "Playback Controls": a half-height sheet with a grabber
// (expandable to full height), opened from the player's ••• menu.
+ (UIViewController *)playbackControlsController;
// "Karaoke Mode": the Sing controls (vocals, backing vocals, strength, model),
// the same kind of sheet, opened from the ••• menu row under Playback Controls.
+ (UIViewController *)karaokeController;
// The Settings page in Deezer's Settings colours, for pushing onto Deezer's
// own Settings navigation (not wrapped; draws Deezer's header when the bar is hidden).
+ (UIViewController *)deezerSettingsPage;
@end
