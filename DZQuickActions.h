#pragma once
#import <UIKit/UIKit.h>

// The one-tap toggles shared by the player's buttons (DZPlayerButtons.x) and
// the lyrics' Karaoke Mode button (DZLyrics.x).

NS_ASSUME_NONNULL_BEGIN

BOOL DZSingReady(void);          // a vocal model is installed
BOOL DZKaraokeIsOn(void);        // lead vocals below 100 %
// Karaoke on: lead vocals 0 %, backing vocals kept (the previous backing level
// is remembered); off: vocals back to 100 % and the backing level restored.
void DZKaraokeToggle(void);

// Presents one of Deezit's sheets over whatever is on top of `vc`.
typedef NS_ENUM(NSInteger, DZSheet) { DZSheetPlaybackControls, DZSheetKaraoke };
void DZPresentSheet(UIViewController *vc, DZSheet sheet);

NS_ASSUME_NONNULL_END
