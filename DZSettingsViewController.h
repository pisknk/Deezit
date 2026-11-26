#pragma once
#import <UIKit/UIKit.h>

// The in-app Deezit settings page (effect switch, presets, speed, reverb).
@interface DZSettingsViewController : UITableViewController
// Wrapped in a navigation controller with a Done button, ready to present.
+ (UIViewController *)presentableController;
// "Playback Controls": Slowed + Reverb, presets, speed, reverb, as a
// half-height sheet with a grabber (expandable to full height), opened by
// holding the player's Slowed + Reverb button.
+ (UIViewController *)playbackControlsController;
// "Karaoke Mode": the Sing controls (vocals, backing vocals, strength, model),
// the same kind of sheet, opened by holding a Karaoke button.
+ (UIViewController *)karaokeController;
// "AutoMix": AutoMix and Tempo matching, the same kind of sheet, opened by
// holding the player's AutoMix button.
+ (UIViewController *)autoMixController;
// The Settings page in Deezer's Settings colours, for pushing onto Deezer's
// own Settings navigation (not wrapped; draws Deezer's header when the bar is hidden).
+ (UIViewController *)deezerSettingsPage;
@end
