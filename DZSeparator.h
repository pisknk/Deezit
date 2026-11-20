#pragma once
#import <AVFoundation/AVFoundation.h>

// "Sing": AI vocal removal on Deezer's decoded audio, before it is played.
//
// Deezer feeds each AVAudioPlayerNode 83 ms PCM buffers (44.1 kHz float
// stereo) and keeps 3 s queued ahead (DZBufferProbe.x). While Sing is on,
// Deezit holds ~0.8 s of those buffers, runs a streaming STFT (4096 / 1024,
// periodic Hann), asks the Spleeter model (DZVocalModel.h) for the vocal mask
// every 32 frames (with 96 frames of context), scales each bin by
// 1 - cut * mask, inverse-STFTs with overlap-add, writes the result back into
// Deezer's own buffers and schedules them in order. No time is added, so the
// position and lyrics stay in sync; the vocal level takes effect ~3 s later.
//
// Safety: buffers pass through untouched until the player has 2.4 s queued;
// if its queue ever falls under 0.35 s while buffers are held, everything is
// released unprocessed and Sing pauses for the rest of that session.

// >0 while Deezit itself schedules (the hook must pass those through).
extern __thread int DZSingInside;

// Called by the scheduleBuffer:atTime:options:completionHandler: hook for
// Deezer's plain sequential schedules. YES = Deezit took the buffer (it will
// be scheduled later, processed or not); NO = schedule it normally.
BOOL DZSingSchedule(AVAudioPlayerNode *node, AVAudioPCMBuffer *buffer, AVAudioNodeCompletionHandler handler);

// Called from the -stop hook before the node stops: drops held buffers
// (their completion handlers still run) and resets the node's session.
void DZSingStop(AVAudioPlayerNode *node);

// One line for the debug panel.
NSString *DZSingStatus(void);

// DZSing.x: installs the AVAudioPlayerNode hooks (respects the audio kill switch).
void DZSingInstall(void);
