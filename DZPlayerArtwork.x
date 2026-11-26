// Animated album cover inside the full-screen player's cover square.
//
// Found in Deezer 11.27.0: the covers are a paging collection view
// (DZRPlayerCoverCollectionViewController, ObjC) of DZRPlayerCoverCollectionViewCell,
// each holding a DZRPlayerCoverView: -configureWithTrack: (a DeezerTrack) and
// an illustrationView (the image), with the HiFi label and Lyrics button on top.
//
// For each cover Deezit finds the album's Apple Music motion cover the same
// way the lock screen does (DZAppleMotionCover, then the song's other
// releases), downloads it with DZMotionFile (the square clip; the 3:4 one,
// cropped by aspect fill, when there is no square one; the cache is shared
// with the lock screen) and plays it muted and looped over the image, inside
// the square, with the same corner radius. Only the cover in the middle of
// the screen plays. Off with Settings → Animated covers → Player, and in Low
// Power Mode.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZAppleMusic.h"
#import "DZMotionFile.h"

@interface DZRPlayerCoverView : UIView
- (UIView *)illustrationView;
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
static NSMutableDictionary<NSString *, id> *sClips;   // key -> file NSURL | NSDate (missed at)
static NSMutableSet<NSString *> *sInFlight;

static NSString *keyFor(NSString *artist, NSString *album, NSString *title) {
    return [[NSString stringWithFormat:@"%@|%@", artist ?: @"", album ?: title ?: @""] lowercaseString];
}

static void finish(NSString *key, NSURL *file, NSString *note) {
    @synchronized (sLock) {
        sClips[key] = file ?: (id)[NSDate date];
        [sInFlight removeObject:key];
    }
    if (file) {
        DZLog("player art: %@ ready (%@)", key, file.lastPathComponent);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:DZPlayerMotionReadyNotification object:key];
        });
    } else {
        DZLog("player art: %@: %@", key, note);
    }
}

static void download(NSString *key, NSString *albumID, NSURL *tall, NSURL *square) {
    if (square) DZMotionFile(square, [albumID stringByAppendingString:@"-1x1"], ^(NSURL *f, NSString *n) { finish(key, f, n); });
    else DZMotionFile(tall, [albumID stringByAppendingString:@"-3x4"], ^(NSURL *f, NSString *n) { finish(key, f, n); });
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
        if ([entry isKindOfClass:[NSDate class]] && -[(NSDate *)entry timeIntervalSinceNow] < 30 * 60) return nil;
        if ([sInFlight containsObject:key]) return nil;
        [sInFlight addObject:key];
    }
    DZAppleMotionCover(title ?: @"", artist, album, duration, ^(NSString *albumID, NSURL *tall, NSURL *square, NSString *note) {
        if (tall || square) { download(key, albumID, tall, square); return; }
        if (!albumID || !title) { finish(key, nil, note); return; }
        DZAppleMotionCoverFromOtherReleases(title, artist, albumID, duration, ^(NSString *otherID, NSURL *t2, NSURL *s2, NSString *note2) {
            if (otherID && (t2 || s2)) download(key, otherID, t2, s2);
            else finish(key, nil, note2);
        });
    });
    return nil;
}

#pragma mark - the video view

@interface DZMotionCoverView : UIView
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) NSURL *file;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic) BOOL active;      // the cover in the middle of the screen
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
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clipReady:) name:DZPlayerMotionReadyNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update) name:DZPrefsChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(update)
                                                     name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player pause];
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

- (void)teardown {
    [self.player pause];
    self.playerLayer.player = nil;
    self.looper = nil;
    self.player = nil;
    self.alpha = 0;
}

- (void)setActive:(BOOL)active {
    if (_active == active) return;
    _active = active;
    [self update];
}

- (void)update {
    BOOL play = self.file && self.active && self.window && enabled();
    if (!play) {
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
        [UIView animateWithDuration:0.6 delay:0.3 options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ self.alpha = 1; } completion:nil];
    }
    [self.player play];
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

// Only the cover in the middle of the strip plays.
static void refreshActive(DZRPlayerCoverCollectionViewController *vc) {
    UICollectionView *cv = [vc respondsToSelector:@selector(coversCollectionView)] ? [vc coversCollectionView] : nil;
    if (![cv isKindOfClass:[UICollectionView class]]) return;
    CGPoint mid = CGPointMake(CGRectGetMidX(cv.bounds), CGRectGetMidY(cv.bounds));
    for (UICollectionViewCell *cell in cv.visibleCells) {
        UIView *cover = kv(cell, @"coverView");
        DZMotionCoverView *m = cover ? motionViewFor(cover, NO) : nil;
        if (!m) continue;
        m.layer.cornerRadius = [(DZRPlayerCoverView *)cover illustrationView].layer.cornerRadius;
        m.active = CGRectContainsPoint(cell.frame, mid);
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
    refreshActive(self);
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)sv {
    %orig;
    refreshActive(self);
}

- (void)playerDidChangeTrack:(id)n {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ refreshActive(self); });
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
            %init(DZPlayerArtworkHooks);
            DZLog("player art: animated covers in the player %@", DZPrefBool(kDZPlayerArtwork) ? @"on" : @"off");
        } else {
            DZLog("player art: Deezer's cover views not as expected, no animated covers in the player");
        }
    });
}
