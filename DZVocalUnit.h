#pragma once
#import <AVFoundation/AVFoundation.h>

// Deezit's vocal-reduction effect (DZVocals.c) as an in-process AUAudioUnit,
// wrapped in an AVAudioUnitEffect ready to attach to Deezer's engine. It reads
// the "Vocals" level straight from the realtime prefs mirror, so moving the
// slider is heard immediately. Returns nil if the unit can't be created
// (the rest of the chain then works without it).
AVAudioUnitEffect *DZVocalUnitCreate(void);
