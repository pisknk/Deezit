#pragma once
// Tempo change without a pitch change (WSOLA), for AutoMix's beat matching.
//
// Works on the buffers Deezer schedules: each input buffer becomes one output
// buffer of a different length, so the song plays faster or slower while
// Deezer's own clock (it counts the frames of the buffers it scheduled, see
// DZRAudioTrackController -outputChannelDidPlay:) keeps following the song.
// Output sample j is input position p(j), where p advances `rate` input frames
// per output frame; the first output sample is input frame `skip`.
//
// 46 ms Hann frames at 50 % overlap; each frame's source is moved by up to
// ±12 ms to where it continues the previous frame best (cross-correlation on a
// 4x decimated mono mix). Plain C, allocation only in Create.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DZStretch DZStretch;

DZStretch *DZStretchCreate(int channels, double sampleRate, double skipFrames);
void DZStretchDestroy(DZStretch *s);

// Frames Process / Finish can write after `frames` more input at `rate`.
int DZStretchCapacity(const DZStretch *s, int frames, double rate);

// Adds `frames` of input (non-interleaved channels) and writes what's ready at
// `rate` (input frames per output frame, 0.8-1.25). Returns frames written.
int DZStretchProcess(DZStretch *s, const float *const *in, int frames, int inStride, double rate,
                     float *const *out, int outStride, int outCapacity);

// Adds `frames` of input and ends the stretch: writes everything held, so that
// the input after this buffer continues it seamlessly unchanged.
int DZStretchFinish(DZStretch *s, const float *const *in, int frames, int inStride,
                    float *const *out, int outStride, int outCapacity);

// Input frames held back (not yet written).
long DZStretchHeld(const DZStretch *s);

#ifdef __cplusplus
}
#endif
