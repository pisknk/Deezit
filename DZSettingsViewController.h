#pragma once
#import <UIKit/UIKit.h>

// The in-app Deezit settings page (effect switch, presets, speed, reverb).
@interface DZSettingsViewController : UITableViewController
// Wrapped in a navigation controller with a Done button, ready to present.
+ (UIViewController *)presentableController;
@end
