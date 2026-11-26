// Animated album cover inside the full-screen player's cover square.
//
// Found in Deezer 11.27.0: the covers are a paging collection view
// (DZRPlayerCoverCollectionViewController, ObjC) of DZRPlayerCoverCollectionViewCell,
// each holding a DZRPlayerCoverView: -configureWithTrack: (a DeezerTrack), a
// track property and an illustrationView (the image), with the HiFi label and
// Lyrics button on top. The strip scrolls itself on a track change
// (-scrollToCoverAtIndex:animated:).
//
// For each cover Deezit finds the album's Apple Music motion cover the same
// way the lock screen does (DZAppleMotionCover, then the song's other
// releases), downloads it with DZMotionFile (the square clip; the 3:4 one,
// cropped by aspect fill, when there is no square one; the cache is shared
// with the lock screen) and plays it muted and looped over the image, inside
// the square, with the same corner radius. Off with Settings → Animated covers
// → Player, and in Low Power Mode.
//
// Only the cover in the middle of the strip plays. Each cover works that out
// itself whenever anything could have changed it: the strip scrolling (by a
// finger or by itself), its layout, a track change, the clip arriving, the app
// coming back. If iOS pauses a cover that should be playing (the app was in
// the background, an audio interruption), it is played again.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAppleMusic.h"
#import "DZMotionFile.h"

@interface DZRPlayerCoverView : UIView
- (UIView *)illustrationView;
- (id)track;
@end

@interface DZRPlayerCoverCollectionViewController : UIViewController
- (UICollectionView *)coversCollectionView;
@end

static NSString *const DZPlayerMotionReadyNotification = @"DZPlayerMotionReadyNotification";

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *str(id v) {
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

static BOOL enabled(void) {
    return DZPrefBool(kDZPlayerArtwork) && !NSProcessInfo.processInfo.isLowPowerModeEnabled;
}

#pragma mark - finding the clip

static NSObject *sLock;
static NSMutableDictionary<NSString *, id> *sClips;   // key -> file NSURL | NSDate (try again from then)
static NSMutableSet<NSString *> *sInFlight;

static NSString *keyFor(NSString *artist, NSString *album, NSString *title) {
    return [[NSString stringWithFormat:@"%@|%@", artist ?: @"", album ?: title ?: @""] lowercaseString];
}

// `retry`: seconds before trying this album again after a miss
static void finish(NSString *key, NSURL *file, NSString *note, NSTimeInterval retry) {
    @synchronized (sLock) {
        sClips[key] = file ?: (id)[NSDate dateWithTimeIntervalSinceNow:retry];
        [sInFlight removeObject:key];
    }
    if (file) {
        DZLog("player art: %@ ready (%@)", key, file.lastPathComponent);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DZPlayerMotionReadyNotification object:key];
        });
    } else {
        DZLog("player art: %@: %@ (trying again in %.0f min)", key, note, retry / 60);
    }
}

// a failed download (a dropped connection) is tried again soon
static void download(NSString *key, NSString *albumID, NSURL *tall, NSURL *square) {
    void (^done)(NSURL *, NSString *) = ^(NSURL *f, NSString *n) { finish(key, f, n, 60); };
    if (square) DZMotionFile(square, [albumID stringByAppendingString:@"-1x1"], done);
    else DZMotionFile(tall, [albumID stringByAppendingString:@"-3x4"], done);
}

// The motion cover's local file for this track, if ready; starts finding it.
static NSURL *clipFor(id track, NSString **keyOut) {
    NSString *title = str(kv(track, @"title"));
    NSString *artist = str(kv(track, @"mainArtistName")) ?: str(kv(track, @"artistName"));
    NSString *album = str(kv(track, @"albumName"));
    if (!artist || !(album || title)) return nil;
    NSString *key = keyFor(artist, album, title);
    if (keyOut) *keyOut = key;
    NSTimeInterval duration = [kv(track, @"duration") doubleValue];
    @synchronized (sLock) {
        id entry = sClips[key];
        if ([entry isKindOfClass:[NSURL class]]) return entry;
        if ([entry isKindOfClass:[NSDate class]] && [(NSDate *)entry timeIntervalSinceNow] > 0) return nil;
        if ([sInFlight containsObject:key]) return nil;
        [sInFlight addObject:key];
    }
    DZAppleMotionCover(title ?: @"", artist, album, duration, ^(NSString *albumID, NSURL *tall, NSURL *square, NSString *note) {
        if (tall || square) { download(key, albumID, tall, square); return; }
        if (!albumID || !title) { finish(key, nil, note, 30 * 60); return; }
        DZAppleMotionCoverFromOtherReleases(title, artist, albumID, duration, ^(NSString *otherID, NSURL *t2, NSURL *s2, NSString *note2) {
            if (otherID && (t2 || s2)) download(key, otherID, t2, s2);
            else finish(key, nil, note2, 30 * 60);
        });
    });
    return nil;
}

#pragma mark - the video view

static void *kDZStatusContext = &kDZStatusContext;

@interface DZMotionCoverView : UIView
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURL *file;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic) BOOL observing;         // KVO on the player's timeControlStatus
@property (nonatomic) BOOL pausedByUs;
@property (nonatomic) BOOL wasPlaying;        // for the log: what update last decided
@property (nonatomic) CFTimeInterval resumeWindow;
@property (nonatomic) int resumes;
@end

@implementation DZMotionCoverView

+ (Class)layerClass {
    return [AVPlayerLayer class];
}

- (AVPlayerLayer *)playerLayer {
    return (AVPlayerLayer *)self.layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.alpha = 0;
        self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(clipReady:) name:DZPlayerMotionReadyNotification object:nil];
        [nc addObserver:self selector:@selector(update) name:DZPrefsChangedNotification object:nil];
        [nc addObserver:self selector:@selector(update) name:NSProcessInfoPowerStateDidChangeNotification object:nil];
        // iOS pauses video in the background; play again on the way back
        [nc addObserver:self selector:@selector(update) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(update) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(update) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(mediaServicesReset) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self teardown];
}

- (void)showTrack:(id)track {
    NSString *key = nil;
    NSURL *file = enabled() ? clipFor(track, &key) : nil;
    if (![key isEqualToString:self.key]) {
        self.key = key;
        self.file = nil;
        [self teardown];
    }
    if (file) self.file = file;
    [self update];
}

- (void)clipReady:(NSNotification *)n {
    if (![n.object isEqual:self.key]) return;
    @synchronized (sLock) {
        id entry = sClips[self.key];
        if ([entry isKindOfClass:[NSURL class]]) self.file = entry;
    }
    [self update];
}

- (void)mediaServicesReset {
    DZLog("player art: media services were reset, %@ starts over", self.key ?: @"(none)");
    [self teardown];
    [self update];
}

- (void)teardown {
    if (self.observing) {
        [self.player removeObserver:self forKeyPath:@"timeControlStatus" context:kDZStatusContext];
        self.observing = NO;
    }
    self.pausedByUs = YES;
    [self.player pause];
    self.playerLayer.player = nil;
    self.looper = nil;
    self.player = nil;
    self.alpha = 0;
    self.wasPlaying = NO;
}

// The cover's cell is the one in the middle of the strip (a cover outside a
// strip, like Deezer's placeholder, counts when it's on screen).
- (BOOL)centered {
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UICollectionViewCell class]]) v = v.superview;
    if (!v) return YES;
    UIView *cv = v.superview;
    while (cv && ![cv isKindOfClass:[UICollectionView class]]) cv = cv.superview;
    if (!cv) return NO;
    CGRect cell = [v convertRect:v.bounds toView:cv];
    return CGRectContainsPoint(cell, CGPointMake(CGRectGetMidX(cv.bounds), CGRectGetMidY(cv.bounds)));
}

// nothing above it hidden or faded out
- (BOOL)visible {
    if (!self.window) return NO;
    for (UIView *v = self.superview; v; v = v.superview)
        if (v.hidden || v.alpha < 0.01) return NO;
    return YES;
}

- (BOOL)shouldPlay {
    return self.file && enabled() && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground &&
           [self visible] && [self centered];
}

- (void)update {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self update]; });
        return;
    }
    BOOL play = [self shouldPlay];
    if (play != self.wasPlaying && self.key && self.file) {
        DZLog("player art: %@ %@", self.key, play ? @"plays" : @"paused (not the cover on screen, or the app is away)");
    }
    self.wasPlaying = play;
    if (!play) {
        self.pausedByUs = YES;
        [self.player pause];
        if (!self.file || !enabled()) [self teardown];
        return;
    }
    if (!self.player) {
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.file];
        AVQueuePlayer *p = [AVQueuePlayer queuePlayerWithItems:@[]];
        p.muted = YES;
        p.preventsDisplaySleepDuringVideoPlayback = NO;
        self.looper = [AVPlayerLooper playerLooperWithPlayer:p templateItem:item];
        self.player = p;
        self.playerLayer.player = p;
        [p addObserver:self forKeyPath:@"timeControlStatus" options:NSKeyValueObservingOptionNew context:kDZStatusContext];
        self.observing = YES;
        [UIView animateWithDuration:0.6 delay:0.3 options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.alpha = 1; } completion:nil];
    }
    self.pausedByUs = NO;
    if (self.player.timeControlStatus != AVPlayerTimeControlStatusPlaying) [self.player play];
}

- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kDZStatusContext) {
        [super observeValueForKeyPath:path ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self statusChanged]; });
}

// Paused by iOS while it should be playing: play again, a few times at most
// in a row, so a pause that keeps coming back doesn't turn into a loop.
- (void)statusChanged {
    AVQueuePlayer *p = self.player;
    if (!p || self.pausedByUs || p.timeControlStatus != AVPlayerTimeControlStatusPaused || ![self shouldPlay]) return;
    if (self.looper.status == AVPlayerLooperStatusFailed) {
        DZLog("player art: %@ loop failed (%@), starting it again", self.key, self.looper.error.localizedDescription);
        [self teardown];
        [self update];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.resumeWindow > 10) {
        self.resumeWindow = now;
        self.resumes = 0;
    }
    if (++self.resumes > 3) {
        if (self.resumes == 4) DZLog("player art: %@ keeps being paused by iOS, left paused until the next change", self.key);
        return;
    }
    DZLog("player art: %@ was paused by iOS, playing again", self.key);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.player == p && !self.pausedByUs && [self shouldPlay]) [p play];
    });
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self update];
}

@end

static void *kMotionKey = &kMotionKey;

static DZMotionCoverView *motionViewFor(UIView *coverView, BOOL create) {
    DZMotionCoverView *m = objc_getAssociatedObject(coverView, kMotionKey);
    if (m || !create) return m;
    UIView *image = [coverView respondsToSelector:@selector(illustrationView)] ? [(DZRPlayerCoverView *)coverView illustrationView] : nil;
    if (![image isKindOfClass:[UIView class]] || !image.superview) return nil;
    m = [[DZMotionCoverView alloc] initWithFrame:image.frame];
    m.translatesAutoresizingMaskIntoConstraints = NO;
    [image.superview insertSubview:m aboveSubview:image];
    [NSLayoutConstraint activateConstraints:@[
        [m.leadingAnchor constraintEqualToAnchor:image.leadingAnchor],
        [m.trailingAnchor constraintEqualToAnchor:image.trailingAnchor],
        [m.topAnchor constraintEqualToAnchor:image.topAnchor],
        [m.bottomAnchor constraintEqualToAnchor:image.bottomAnchor],
    ]];
    m.layer.cornerRadius = image.layer.cornerRadius;
    m.layer.cornerCurve = image.layer.cornerCurve;
    objc_setAssociatedObject(coverView, kMotionKey, m, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return m;
}

static __weak DZRPlayerCoverCollectionViewController *sStrip;   // the player on screen

// Every visible cover: its video view (made now if the setting was just turned
// on), its clip looked up again if it hasn't got one, and play / pause.
static void refreshStrip(DZRPlayerCoverCollectionViewController *vc) {
    UICollectionView *cv = [vc respondsToSelector:@selector(coversCollectionView)] ? [vc coversCollectionView] : nil;
    if (![cv isKindOfClass:[UICollectionView class]]) return;
    sStrip = vc;
    for (UICollectionViewCell *cell in cv.visibleCells) {
        UIView *cover = kv(cell, @"coverView");
        if (!cover) continue;
        DZMotionCoverView *m = motionViewFor(cover, enabled());
        if (!m) continue;
        m.layer.cornerRadius = [(DZRPlayerCoverView *)cover illustrationView].layer.cornerRadius;
        if (!m.file && enabled() && [cover respondsToSelector:@selector(track)]) [m showTrack:[(DZRPlayerCoverView *)cover track]];
        else [m update];
    }
}

%group DZPlayerArtworkHooks

%hook DZRPlayerCoverView

- (void)configureWithTrack:(id)track {
    %orig;
    if (!enabled() && !objc_getAssociatedObject(self, kMotionKey)) return;
    [motionViewFor(self, YES) showTrack:track];
}

%end

%hook DZRPlayerCoverCollectionViewController

- (void)viewDidLayoutSubviews {
    %orig;
    refreshStrip(self);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    %orig;
    refreshStrip(self);
}

- (void)playerDidChangeTrack:(id)n {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ refreshStrip(self); });
}

// the strip scrolling, by a finger or by itself (a track change): the cover
// that reaches the middle plays, the one that leaves it pauses
%new
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    refreshStrip(self);
}

%new
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)sv {
    refreshStrip(self);
}

%end

%end

static BOOL owns(Class c, SEL s) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == s;
    free(list);
    return found;
}

void DZPlayerArtworkInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sLock = [NSObject new];
        sClips = [NSMutableDictionary dictionary];
        sInFlight = [NSMutableSet set];
        Class cover = objc_getClass("DZRPlayerCoverView"), strip = objc_getClass("DZRPlayerCoverCollectionViewController");
        if (owns(cover, @selector(configureWithTrack:)) && owns(cover, @selector(illustrationView)) &&
            owns(strip, @selector(viewDidLayoutSubviews)) && owns(strip, @selector(scrollViewDidEndDecelerating:)) &&
            owns(strip, @selector(playerDidChangeTrack:)) && owns(strip, @selector(coversCollectionView))) {
            // (%new only adds them where Deezer has none; the other hooks still refresh)
            if (owns(strip, @selector(scrollViewDidScroll:)))
                DZLog("player art: Deezer's strip has its own scrollViewDidScroll:, covers refresh on layout / track changes only");
            %init(DZPlayerArtworkHooks);
            // the setting turned on: covers already on screen get their video now
            [[NSNotificationCenter defaultCenter] addObserverForName:DZPrefsChangedNotification object:nil
                                                               queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                DZRPlayerCoverCollectionViewController *vc = sStrip;
                if (vc) refreshStrip(vc);
            }];
            DZLog("player art: animated covers in the player %@", DZPrefBool(kDZPlayerArtwork) ? @"on" : @"off");
        } else {
            DZLog("player art: Deezer's cover views not as expected, no animated covers in the player");
        }
    });
}
