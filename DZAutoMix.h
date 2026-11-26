#pragma once
#import <Foundation/Foundation.h>

// AutoMix (DZAutoMix.x): each crossfade planned from the two songs - from
// Apple Music's analysis, or Deezit's own, learned while a song plays to its
// end. Songs neither knows keep Deezer's crossfade setting.
void DZAutoMixInstall(void);
NSString *DZAutoMixStatus(void);          // one line for the debug panel
NSUInteger DZAutoMixLearnedSongs(void);   // songs Deezit has analysed itself
