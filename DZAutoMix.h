#pragma once
#import <Foundation/Foundation.h>

// AutoMix (DZAutoMix.x): each crossfade planned from the two songs - from
// Apple Music's analysis, or Deezit's own, learned while a song plays to its
// end. Songs neither knows keep Deezer's crossfade setting.
void DZAutoMixInstall(void);
NSString *DZAutoMixStatus(void);          // one line for the debug panel
NSUInteger DZAutoMixLearnedSongs(void);   // songs Deezit has analysed itself

@class AVAudioPlayerNode, AVAudioPCMBuffer;
// From the buffer probe: a buffer Deezer is scheduling on a player node (the
// song it belongs to is known from the read just before it, on that thread).
// Returns the buffer to schedule instead: the same one, or, while AutoMix
// changes the next song's tempo (only when canReplace), a new one of another
// length. Deezer's completion handler goes with whichever is scheduled.
AVAudioPCMBuffer *DZAutoMixScheduledBuffer(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer, BOOL canReplace);
