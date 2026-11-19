// Animated album covers on the lock screen (iOS 26+), no jailbreak.
//
// iOS 26 added MPMediaItemAnimatedArtwork: an app puts one in its now-playing
// info under one of +[MPNowPlayingInfoCenter supportedAnimatedArtworkKeys]
// (a 3:4 and a 1:1 shape), and the lock screen plays the local video it hands
// out. Deezer has no motion covers, so Deezit:
//   1. hooks -[MPNowPlayingInfoCenter setNowPlayingInfo:] in Deezer's process
//      and reads title / artist / album from what Deezer sets
//   2. finds the album's Apple Music motion cover (DZAppleMusic.m)
//   3. downloads it as a local MP4 (DZMotionFile.m)
//   4. adds the MPMediaItemAnimatedArtwork to every now-playing update for
//      that album, and re-sends the latest info once it is ready
//
// Every iOS 26 symbol is looked up at runtime (class by name, selector,
// dlsym for the key constants), so the build doesn't depend on the SDK and
// older iOS versions simply skip it. Off in Low Power Mode and with the
// "Animated album covers" switch in Deezit's settings.

#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAppleMusic.h"
#import "DZMotionFile.h"

typedef void (^DZImageDone)(UIImage *image);
typedef void (^DZURLDone)(NSURL *url);

static NSObject *sLock;
static NSDictionary *sLastInfo;              // Deezer's latest info, without our key
static CFTimeInterval sLastInfoAt;
static __weak MPNowPlayingInfoCenter *sCenter;
static NSString *sCurrentKey;                // album now playing
static NSMutableDictionary *sResults;        // album key -> @[infoKey, artwork] | NSDate (failed at)
static NSMutableSet<NSString *> *sInFlight;
static NSString *sKey3x4, *sKey1x1;          // what this iOS offers
static NSUInteger sReady, sMisses;
static NSString *sLastNote;
static BOOL sLoggedLowPower;

#pragma mark - iOS 26 API, looked up at runtime

static NSString *constantNamed(const char *name) {
    NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, name);
    return p ? *p : nil;
}

static BOOL apiAvailable(void) {
    return NSClassFromString(@"MPMediaItemAnimatedArtwork") &&
           [MPNowPlayingInfoCenter respondsToSelector:NSSelectorFromString(@"supportedAnimatedArtworkKeys")];
}

static void readOfferedKeys(void) {
    id keys = ((id (*)(id, SEL))objc_msgSend)([MPNowPlayingInfoCenter class], NSSelectorFromString(@"supportedAnimatedArtworkKeys"));
    NSString *k3 = constantNamed("MPNowPlayingInfoProperty3x4AnimatedArtwork");
    NSString *k1 = constantNamed("MPNowPlayingInfoProperty1x1AnimatedArtwork");
    NSMutableArray *names = [NSMutableArray array];
    for (id key in [keys isKindOfClass:[NSArray class]] || [keys isKindOfClass:[NSSet class]] ? keys : @[]) {
        if (![key isKindOfClass:[NSString class]]) continue;
        [names addObject:key];
        if ([key isEqualToString:k3 ?: @""] || [key containsString:@"3x4"]) sKey3x4 = key;
        else if ([key isEqualToString:k1 ?: @""] || [key containsString:@"1x1"]) sKey1x1 = key;
    }
    DZLog("lock art: iOS offers %@ (3:4 %@, 1:1 %@)", names.count ? [names componentsJoinedByString:@", "] : @"no keys",
          sKey3x4 ? @"yes" : @"no", sKey1x1 ? @"yes" : @"no");
}

static id makeArtwork(NSString *artworkID, NSURL *file, MPMediaItemArtwork *still) {
    Class cls = NSClassFromString(@"MPMediaItemAnimatedArtwork");
    SEL init = NSSelectorFromString(@"initWithArtworkID:previewImageRequestHandler:videoAssetFileURLRequestHandler:");
    if (!cls || ![cls instancesRespondToSelector:init]) return nil;
    void (^preview)(CGSize, DZImageDone) = ^(CGSize size, DZImageDone done) {
        DZMotionPreview(file, size, ^(UIImage *image) {
            done(image ?: [still imageWithSize:size]);
        });
    };
    void (^video)(CGSize, DZURLDone) = ^(CGSize size, DZURLDone done) {
        done(file);
    };
    @try {
        return ((id (*)(id, SEL, NSString *, id, id))objc_msgSend)([cls alloc], init, artworkID, preview, video);
    } @catch (NSException *ex) {
        DZLog("lock art: MPMediaItemAnimatedArtwork refused: %@", ex.reason);
        return nil;
    }
}

#pragma mark - state

static NSString *stringIn(NSDictionary *info, NSString *key) {
    id v = info[key];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

static NSString *albumKey(NSString *artist, NSString *album, NSString *title) {
    return [[NSString stringWithFormat:@"%@|%@", artist ?: @"", album.length ? album : (title ?: @"")] lowercaseString];
}

// Sends Deezer's latest info again (with the playback position moved on), so
// a cover that just became ready shows without waiting for Deezer's next update.
static void resend(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary *info;
        MPNowPlayingInfoCenter *center;
        CFTimeInterval age;
        @synchronized (sLock) {
            info = [sLastInfo mutableCopy];
            center = sCenter;
            age = CACurrentMediaTime() - sLastInfoAt;
        }
        if (!info || !center) return;
        NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
        double rate = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];
        if ([elapsed isKindOfClass:[NSNumber class]] && rate > 0) {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed.doubleValue + age * rate);
        }
        center.nowPlayingInfo = info;
    });
}

static void giveUp(NSString *key, NSString *note) {
    @synchronized (sLock) {
        sResults[key] = [NSDate date];
        [sInFlight removeObject:key];
        sMisses++;
        sLastNote = note;
    }
    DZLog("lock art: no animated cover: %@", note);
}

static void resolve(NSString *key, NSString *title, NSString *artist, NSString *album, NSTimeInterval duration,
                    MPMediaItemArtwork *still) {
    DZAppleMotionCover(title ?: @"", artist, album, duration, ^(NSString *albumID, NSURL *tall, NSURL *square, NSString *note) {
        DZLog("lock art: \"%@\" / %@: %@", album ?: title, artist, note);
        NSString *infoKey = nil, *shape = nil;
        NSURL *video = nil;
        if (sKey3x4 && tall) { infoKey = sKey3x4; video = tall; shape = @"3x4"; }
        else if (sKey1x1 && square) { infoKey = sKey1x1; video = square; shape = @"1x1"; }
        if (!video) {
            giveUp(key, albumID ? @"Apple Music has no motion cover in a shape this iOS offers" : note);
            return;
        }
        NSString *name = [NSString stringWithFormat:@"%@-%@", albumID, shape];
        DZMotionFile(video, name, ^(NSURL *file, NSString *fileNote) {
            if (!file) { giveUp(key, [@"video download: " stringByAppendingString:fileNote]); return; }
            id artwork = makeArtwork([@"deezit-" stringByAppendingString:name], file, still);
            if (!artwork) { giveUp(key, @"couldn't create MPMediaItemAnimatedArtwork"); return; }
            BOOL current;
            @synchronized (sLock) {
                sResults[key] = @[infoKey, artwork];
                [sInFlight removeObject:key];
                sReady++;
                sLastNote = [NSString stringWithFormat:@"%@ (%@)", album ?: title, shape];
                current = [sCurrentKey isEqualToString:key];
            }
            DZLog("lock art: ready, %@ %@ (%@)", shape, file.lastPathComponent, fileNote);
            if (current) resend();
        });
    });
}

// Deezer's info, plus the animated cover when there is one for this album.
static NSDictionary *withArtwork(MPNowPlayingInfoCenter *center, NSDictionary *info) {
    if (![info isKindOfClass:[NSDictionary class]] || !info.count) {
        @synchronized (sLock) { sLastInfo = nil; sCurrentKey = nil; }
        return info;
    }
    NSString *title = stringIn(info, MPMediaItemPropertyTitle);
    NSString *artist = stringIn(info, MPMediaItemPropertyArtist);
    NSString *album = stringIn(info, MPMediaItemPropertyAlbumTitle);
    if (!artist || !(album || title)) return info;
    NSString *key = albumKey(artist, album, title);

    BOOL start = NO;
    id entry;
    @synchronized (sLock) {
        sLastInfo = [info copy];
        sLastInfoAt = CACurrentMediaTime();
        sCenter = center;
        sCurrentKey = key;
        entry = sResults[key];
        BOOL recentMiss = [entry isKindOfClass:[NSDate class]] && -[(NSDate *)entry timeIntervalSinceNow] < 30 * 60;
        if (!entry || ([entry isKindOfClass:[NSDate class]] && !recentMiss)) {
            if (![sInFlight containsObject:key]) { [sInFlight addObject:key]; start = YES; }
        }
    }
    if (start) {
        NSNumber *duration = info[MPMediaItemPropertyPlaybackDuration];
        id still = info[MPMediaItemPropertyArtwork];
        resolve(key, title, artist, album, [duration isKindOfClass:[NSNumber class]] ? duration.doubleValue : 0,
                [still isKindOfClass:[MPMediaItemArtwork class]] ? still : nil);
    }
    if (![entry isKindOfClass:[NSArray class]]) return info;
    NSMutableDictionary *out = [info mutableCopy];
    out[((NSArray *)entry)[0]] = ((NSArray *)entry)[1];
    return out;
}

static BOOL active(void) {
    if (!DZPrefBool(kDZLockArtwork)) return NO;
    if (NSProcessInfo.processInfo.isLowPowerModeEnabled) {
        if (!sLoggedLowPower) { sLoggedLowPower = YES; DZLog("lock art: Low Power Mode, animated covers paused"); }
        return NO;
    }
    return YES;
}

%group DZLockArtworkHooks

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (!active()) {
        %orig;
        return;
    }
    %orig(withArtwork(self, info));
}

%end

%end

void DZLockArtworkInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        if (!apiAvailable()) {
            DZLog("lock art: this iOS has no animated now-playing artwork (needs iOS 26), skipped");
            return;
        }
        sResults = [NSMutableDictionary dictionary];
        sInFlight = [NSMutableSet set];
        readOfferedKeys();
        if (!sKey3x4 && !sKey1x1) return;
        %init(DZLockArtworkHooks);
        // switch flipped in settings: show / remove the cover right away
        [[NSNotificationCenter defaultCenter] addObserverForName:DZPrefsChangedNotification object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            static BOOL last = YES;
            BOOL now = DZPrefBool(kDZLockArtwork);
            if (now != last) { last = now; resend(); }
        }];
        DZLog("lock art: animated lock-screen covers armed");
    });
}

NSString *DZLockArtworkStatus(void) {
    @synchronized (sLock) {
        if (!sResults) return apiAvailable() ? @"lock art: no usable keys" : @"lock art: needs iOS 26";
        return [NSString stringWithFormat:@"lock art: %@ · keys %@%@ · ready %lu, misses %lu%@",
                DZPrefBool(kDZLockArtwork) ? @"on" : @"off", sKey3x4 ? @"3:4 " : @"", sKey1x1 ? @"1:1" : @"",
                (unsigned long)sReady, (unsigned long)sMisses,
                sLastNote ? [@" · last: " stringByAppendingString:sLastNote] : @""];
    }
}
