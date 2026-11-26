#pragma once
#import <Foundation/Foundation.h>

// What AutoMix knows about a song, from Apple Music's audio analysis or from
// Deezit's own (DZSongAnalyzer, run on the audio Deezer decodes), and the
// crossfade it plans from that. No hooks here: DZAutoMix.x does those.

NS_ASSUME_NONNULL_BEGIN

@interface DZSongInfo : NSObject
@property (nonatomic, copy) NSString *source;            // @"apple" or @"deezit"
@property (nonatomic) double duration;                   // s
@property (nonatomic) double bpm;                        // 0 = unknown
@property (nonatomic) double musicStart;                 // s: first audible music
@property (nonatomic) double musicEnd;                   // s: where the music winds down
@property (nonatomic, copy) NSArray<NSNumber *> *bars;   // s: downbeats, ascending (may be empty)
@property (nonatomic) double beatConfidence;             // own analysis: 0 ... 1
+ (nullable instancetype)fromPlist:(NSDictionary *)d;
- (NSDictionary *)plist;
// The first downbeat at or after t (nil when there are no bars).
- (nullable NSNumber *)firstBarFrom:(double)t;
@end

// Fed the audio of one song from its start, as Deezer decodes it; -finish
// returns the analysis (nil when there was too little or no music). Not
// thread-safe; -finish is the heavy part, call it off the audio threads.
@interface DZSongAnalyzer : NSObject
- (instancetype)initWithSampleRate:(double)sampleRate;
- (void)addChannels:(float *const _Nonnull *_Nonnull)channels count:(int)channelCount frames:(int)frames stride:(int)stride;
@property (nonatomic, readonly) double seconds;          // audio fed so far
- (nullable DZSongInfo *)finish;
@end

// Apple's catalog: the song's `audio-analysis` attributes (and its duration).
DZSongInfo *_Nullable DZSongInfoFromApple(NSDictionary *audioAnalysis, double durationSeconds);

// Apple's and Deezit's knowledge of one song as one: where the music ends from
// Deezit's own analysis (it measured Deezer's file), bars from Apple when its
// file has the same length. `note` says which came from where.
DZSongInfo *_Nullable DZSongInfoMerge(DZSongInfo *_Nullable apple, DZSongInfo *_Nullable own, NSString *_Nullable *_Nullable note);

// The crossfade for A followed by B, in seconds, for Deezer's
// crossFadeDurationForPlayable:followedByPlayable: (Deezer starts B and fades
// A out at A's end minus this). Lands B's first downbeat on A's bar line where
// A's music winds down. `durationA`: Deezer's length of A (0 = take A's).
// Returns -1 without knowledge of A.
double DZPlanCrossfade(DZSongInfo *_Nullable a, DZSongInfo *_Nullable b, double durationA, NSString *_Nullable *_Nullable why);

// Storage: Application Support/Deezit/AutoMix/<source>/<ISRC>.plist
DZSongInfo *_Nullable DZSongInfoLoad(NSString *isrc, NSString *source);
void DZSongInfoSave(DZSongInfo *info, NSString *isrc);
NSUInteger DZSongInfoCount(NSString *source);
// Apple has no analysis for this ISRC (remembered for a week).
BOOL DZAppleMissingRecently(NSString *isrc);
void DZAppleMarkMissing(NSString *isrc);

NS_ASSUME_NONNULL_END
