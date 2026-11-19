#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Apple Music catalog lookups for the animated lock-screen cover, adapted
// from pisknk/twenty-one-reborn (TJCatalogMatch / TJCatalogAPI):
//   1. iTunes Search API (public, no token): Deezer's album / track names ->
//      the Apple Music album ID
//   2. amp-api catalog (web player token, scraped from music.apple.com and
//      kept until it expires): album ID -> editorialVideo motion covers
//
// `done` is called once, on an arbitrary queue. `tall` is the 3:4 motion cover
// and `square` the 1:1 one; either or both can be nil. `note` says what
// happened, for the debug log.
typedef void (^DZMotionCoverResult)(NSString * _Nullable albumID, NSURL * _Nullable tall,
                                    NSURL * _Nullable square, NSString *note);

void DZAppleMotionCover(NSString *title, NSString *artist, NSString * _Nullable album,
                        NSTimeInterval duration, DZMotionCoverResult done);

NS_ASSUME_NONNULL_END
