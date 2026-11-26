// Slowed + Reverb, Karaoke Mode and AutoMix buttons in the full-screen
// player's action row, next to Share.
//
// Found in Deezer 11.27.0: the row under the cover is
// DZRPlayerTrackActionsController (ObjC-visible): a stackView holding
// shareButton, a spacer, addToPlaylistButton, likeButton (and dislike /
// download / ban in some contexts). -updateButtons takes the arranged views
// out and puts back the ones the current track needs. The buttons are
// DZRPlayerButton (a UIButton): -initWithImage:target:action:, +defaultSize,
// default / highlighted / selected tint colours, which Deezer changes with the
// cover (dark icons over a light cover).
//
// After every -updateButtons the three buttons go back in right after Share,
// in the share button's current colours (followed when Deezer recolours it).
// Tap: turns the feature on / off (filled glyph when on, outline when off,
// like the heart). Touch and hold: its sheet (Playback Controls; Karaoke
// Mode; AutoMix's switch is in Playback Controls).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DZLog.h"
#import "DZPrefs.h"
#import "DZQuickActions.h"
#import "DZSettingsViewController.h"
#import "DZVocalModel.h"
#import "DZDemucsModel.h"

@interface DZRPlayerTrackActionsController : NSObject
- (UIStackView *)stackView;
- (UIButton *)shareButton;
- (UIViewController *)playerMainViewController;
@end

// Deezer's DZRPlayerButton, declared so ARC sees a real init: its
// -initWithImage:target:action: returns a different object than the one
// allocated (it makes one with +buttonWithType:), so calling it through a
// cast objc_msgSend released the allocated one twice and crashed at launch.
// Only messaged through an `id` (never the class symbol, which isn't linked).
@protocol DZPlayerButtonAPI <NSObject>
- (instancetype)initWithImage:(UIImage *)image target:(id)target action:(SEL)action;
+ (CGFloat)defaultSize;
@optional
- (void)setImage:(UIImage *)image;
- (UIColor *)defaultTintColor;
- (void)setDefaultTintColor:(UIColor *)c;
- (UIColor *)highlightedTintColor;
- (void)setHighlightedTintColor:(UIColor *)c;
- (UIColor *)selectedTintColor;
- (void)setSelectedTintColor:(UIColor *)c;
- (void)setActive:(BOOL)active;
@end

// placeholder; %init binds it to DZRPlayerButton
@interface DZPlayerButtonHookTarget : UIButton
@end

static NSString *const kDZPrevBackingKey = @"karaokeTapPrevBacking";

#pragma mark - shared toggles

BOOL DZSingReady(void) {
    return DZVocalModelGetState() == DZVocalModelReady || DZLabModelInstalled(kDZLabMDX);
}

BOOL DZKaraokeIsOn(void) {
    return DZSingReady() && DZPrefFloat(kDZVocals) < 0.995f;
}

void DZKaraokeToggle(void) {
    if (DZKaraokeIsOn()) {
        DZPrefSetMany(@{ kDZVocals: @1.0f, kDZBackingVocals: @(DZPrefFloat(kDZPrevBackingKey)) });
        DZLog("karaoke: off");
    } else {
        DZPrefSetMany(@{ kDZPrevBackingKey: @(DZPrefFloat(kDZBackingVocals)), kDZVocals: @0.0f, kDZBackingVocals: @1.0f });
        DZLog("karaoke: on (lead vocals 0 %%, backing vocals kept)");
    }
}

void DZPresentSheet(UIViewController *vc, DZSheet sheet) {
    UIViewController *top = vc;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    if (!top.view.window) return;
    UIViewController *pc = sheet == DZSheetKaraoke ? [DZSettingsViewController karaokeController]
                                                   : [DZSettingsViewController playbackControlsController];
    [top presentViewController:pc animated:YES completion:nil];
}

#pragma mark - the buttons

typedef NS_ENUM(NSInteger, DZQuick) { DZQuickEffect, DZQuickKaraoke, DZQuickAutoMix, DZQuickCount };

// Outline when off, filled when on (like Deezer's heart); the first symbol
// this iOS has wins. The tortoise is about twice as wide as it is tall, so it
// is drawn smaller to sit in the row like the other icons.
static UIImage *quickImage(DZQuick q, BOOL on, CGFloat point) {
    if (q == DZQuickEffect) point = round(point * 0.8);
    NSArray<NSString *> *names;
    switch (q) {
        case DZQuickEffect: names = on ? @[@"tortoise.fill"] : @[@"tortoise"]; break;
        case DZQuickKaraoke: names = on ? @[@"microphone.fill", @"mic.fill"] : @[@"microphone", @"mic"]; break;
        default: names = on ? @[@"infinity.circle.fill"] : @[@"infinity.circle"]; break;
    }
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightRegular];
    for (NSString *n in names) {
        UIImage *img = [UIImage systemImageNamed:n withConfiguration:cfg];
        if (img) return img;
    }
    return [UIImage systemImageNamed:@"circle" withConfiguration:cfg];
}

static NSString *quickName(DZQuick q) {
    switch (q) {
        case DZQuickEffect: return @"Slowed + Reverb";
        case DZQuickKaraoke: return @"Karaoke Mode";
        default: return @"AutoMix";
    }
}

static BOOL quickIsOn(DZQuick q) {
    switch (q) {
        case DZQuickEffect: return DZPrefBool(kDZEnabled);
        case DZQuickKaraoke: return DZKaraokeIsOn();
        default: return DZPrefBool(kDZAutoMix);
    }
}

@interface DZQuickButtons : NSObject
@property (nonatomic, weak) DZRPlayerTrackActionsController *controller;
@property (nonatomic, strong) NSArray<UIButton *> *buttons;
@property (nonatomic) CGFloat point;
@property (nonatomic, weak) UIButton *sizedLike;                      // the share button they're sized like
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *sizeMatch;
- (void)syncLook;
@end

static void *kDZShareMirrorKey = &kDZShareMirrorKey;   // Deezer's share button -> our buttons (weak box)

@implementation DZQuickButtons

- (instancetype)initWithController:(DZRPlayerTrackActionsController *)controller {
    if ((self = [super init])) {
        _controller = controller;
        NSMutableArray *buttons = [NSMutableArray array];
        UIButton *share = [controller respondsToSelector:@selector(shareButton)] ? [controller shareButton] : nil;
        Class cls = NSClassFromString(@"DZRPlayerButton");
        SEL init = NSSelectorFromString(@"initWithImage:target:action:");
        CGFloat side = 44;
        SEL sizeSel = NSSelectorFromString(@"defaultSize");
        if ([cls respondsToSelector:sizeSel]) {
            CGFloat s = [(Class<DZPlayerButtonAPI>)cls defaultSize];
            if (s > 20 && s < 80) side = s;
        }
        CGFloat point = MAX(18, MIN(24, side * 0.5));
        _point = point;
        for (NSInteger q = 0; q < DZQuickCount; q++) {
            UIImage *img = quickImage(q, NO, point);
            UIButton *b = nil;
            if ([cls isSubclassOfClass:[UIButton class]] && [cls instancesRespondToSelector:init]) {
                @try {
                    id<DZPlayerButtonAPI> fresh = (id<DZPlayerButtonAPI>)[cls alloc];
                    id made = [fresh initWithImage:img target:self action:@selector(tapped:)];
                    b = [made isKindOfClass:[UIButton class]] ? made : nil;
                    // its +buttonWithType: object may not carry the target: make sure
                    if (b && ![[b actionsForTarget:self forControlEvent:UIControlEventTouchUpInside] containsObject:@"tapped:"])
                        [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
                } @catch (NSException *e) {
                    b = nil;
                }
            }
            if (!b) {
                b = [UIButton buttonWithType:UIButtonTypeSystem];
                [b setImage:img forState:UIControlStateNormal];
                [b addTarget:self action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
                b.tintColor = share.tintColor ?: UIColor.whiteColor;
            }
            b.tag = q;
            b.accessibilityLabel = quickName(q);
            b.accessibilityHint = @"Touch and hold for options.";
            b.translatesAutoresizingMaskIntoConstraints = NO;
            NSLayoutConstraint *w = [b.widthAnchor constraintEqualToConstant:side];
            w.priority = UILayoutPriorityDefaultHigh;   // gives way if the row runs out of room
            [NSLayoutConstraint activateConstraints:@[w, [b.heightAnchor constraintEqualToConstant:side]]];
            UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
            [b addGestureRecognizer:lp];
            [buttons addObject:b];
        }
        _buttons = buttons;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:DZPrefsChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:DZVocalModelChangedNotification object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Filled glyph when on, outline when off (no dot).
- (void)refresh {
    for (UIButton *b in self.buttons) {
        BOOL on = quickIsOn(b.tag);
        UIImage *img = quickImage(b.tag, on, self.point);
        id<DZPlayerButtonAPI> pb = (id<DZPlayerButtonAPI>)b;
        if ([pb respondsToSelector:@selector(setActive:)]) [pb setActive:NO];
        if ([pb respondsToSelector:@selector(setImage:)]) [pb setImage:img];
        else [b setImage:img forState:UIControlStateNormal];
        b.accessibilityValue = on ? @"On" : @"Off";
    }
    [self syncLook];
}

// Deezer recolours its buttons with the cover (dark icons on a light
// background): take whatever its share button has now.
- (void)syncLook {
    DZRPlayerTrackActionsController *c = self.controller;
    UIButton *share = [c respondsToSelector:@selector(shareButton)] ? [c shareButton] : nil;
    if (!share) return;
    if (objc_getAssociatedObject(share, kDZShareMirrorKey) == nil) {
        NSPointerArray *box = [NSPointerArray weakObjectsPointerArray];
        [box addPointer:(__bridge void *)self];
        objc_setAssociatedObject(share, kDZShareMirrorKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id<DZPlayerButtonAPI> s = (id<DZPlayerButtonAPI>)share;
    for (UIButton *b in self.buttons) {
        id<DZPlayerButtonAPI> pb = (id<DZPlayerButtonAPI>)b;
        if ([s respondsToSelector:@selector(defaultTintColor)] && [pb respondsToSelector:@selector(setDefaultTintColor:)] && s.defaultTintColor)
            [pb setDefaultTintColor:s.defaultTintColor];
        if ([s respondsToSelector:@selector(highlightedTintColor)] && [pb respondsToSelector:@selector(setHighlightedTintColor:)] && s.highlightedTintColor)
            [pb setHighlightedTintColor:s.highlightedTintColor];
        if ([s respondsToSelector:@selector(selectedTintColor)] && [pb respondsToSelector:@selector(setSelectedTintColor:)] && s.selectedTintColor)
            [pb setSelectedTintColor:s.selectedTintColor];
        if (share.tintColor) b.tintColor = share.tintColor;
    }
}

- (UIViewController *)host {
    DZRPlayerTrackActionsController *c = self.controller;
    UIViewController *vc = [c respondsToSelector:@selector(playerMainViewController)] ? [c playerMainViewController] : nil;
    if (vc) return vc;
    UIResponder *r = self.buttons.firstObject;
    while (r && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    return (UIViewController *)r;
}

- (void)tapped:(UIButton *)b {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    switch (b.tag) {
        case DZQuickEffect:
            DZPrefSet(kDZEnabled, @(!DZPrefBool(kDZEnabled)));
            DZLog("player: Slowed + Reverb %@", DZPrefBool(kDZEnabled) ? @"on" : @"off");
            break;
        case DZQuickKaraoke:
            if (!DZSingReady()) DZPresentSheet([self host], DZSheetKaraoke);   // says how to get a model
            else DZKaraokeToggle();
            break;
        default:
            DZPrefSet(kDZAutoMix, @(!DZPrefBool(kDZAutoMix)));
            DZLog("player: AutoMix %@", DZPrefBool(kDZAutoMix) ? @"on" : @"off");
            break;
    }
    [self refresh];
}

- (void)held:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    DZPresentSheet([self host], g.view.tag == DZQuickKaraoke ? DZSheetKaraoke : DZSheetPlaybackControls);
}

@end

static void *kDZQuickKey = &kDZQuickKey;

// Deezer's row is Share, a spacer, then its buttons on the right. With three
// more after Share the spacer squeezed them, so the spacing came out uneven:
// the spacer is hidden, the row spaced evenly, and the new buttons get the
// share button's size, so every icon is the same distance from the next.
static void evenRow(UIStackView *stack, DZQuickButtons *q, UIButton *share) {
    NSMutableArray<NSString *> *hidden = [NSMutableArray array];
    for (UIView *v in stack.arrangedSubviews) {
        // only a plain empty view: anything else may be one of Deezer's buttons
        if (!v.hidden && [v class] == [UIView class] && v.subviews.count == 0) {
            v.hidden = YES;
            [hidden addObject:NSStringFromClass([v class])];
        }
    }
    UIStackViewDistribution was = stack.distribution;
    if (was != UIStackViewDistributionEqualSpacing) stack.distribution = UIStackViewDistributionEqualSpacing;
    if (share && (q.sizedLike != share || !q.sizeMatch.firstObject.isActive)) {
        if (q.sizeMatch) [NSLayoutConstraint deactivateConstraints:q.sizeMatch];
        NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
        for (UIButton *b in q.buttons) {
            NSLayoutConstraint *w = [b.widthAnchor constraintEqualToAnchor:share.widthAnchor];
            w.priority = UILayoutPriorityRequired - 1;
            [cs addObject:w];
        }
        [NSLayoutConstraint activateConstraints:cs];
        q.sizeMatch = cs;
        q.sizedLike = share;
    }
    static BOOL logged;
    if (!logged) {
        logged = YES;
        NSMutableArray<NSString *> *row = [NSMutableArray array];
        for (UIView *v in stack.arrangedSubviews)
            [row addObject:[NSString stringWithFormat:@"%@%@ %.0f", NSStringFromClass([v class]), v.hidden ? @" (hidden)" : @"",
                            v.bounds.size.width]];
        DZLog("player: row spaced evenly (distribution was %ld, spacing %.0f, share %.0f wide; spacer hidden: %@) · %@",
              (long)was, stack.spacing, share.bounds.size.width, hidden.count ? @"yes" : @"none found",
              [row componentsJoinedByString:@", "]);
    }
}

// Puts the buttons back right after Share (Deezer has just rebuilt the row).
static void placeButtons(DZRPlayerTrackActionsController *c) {
    UIStackView *stack = [c respondsToSelector:@selector(stackView)] ? [c stackView] : nil;
    if (![stack isKindOfClass:[UIStackView class]]) return;
    DZQuickButtons *q = objc_getAssociatedObject(c, kDZQuickKey);
    if (!q) {
        q = [[DZQuickButtons alloc] initWithController:c];
        objc_setAssociatedObject(c, kDZQuickKey, q, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DZLog("player: Slowed + Reverb, Karaoke Mode and AutoMix buttons added next to Share");
    }
    for (UIButton *b in q.buttons) {
        if ([stack.arrangedSubviews containsObject:b]) [stack removeArrangedSubview:b];
    }
    UIButton *share = [c respondsToSelector:@selector(shareButton)] ? [c shareButton] : nil;
    NSUInteger idx = 0;
    NSUInteger shareIdx = share ? [stack.arrangedSubviews indexOfObject:share] : NSNotFound;
    if (shareIdx != NSNotFound) idx = shareIdx + 1;
    for (UIButton *b in q.buttons) {
        b.hidden = NO;
        [stack insertArrangedSubview:b atIndex:idx++];
    }
    evenRow(stack, q, share);
    [q refresh];
}

// Crash guard: a marker file is written before the first placing of a launch
// and removed once it has worked. If Deezer died in between, the next launch
// finds the marker and leaves the row alone, so a broken build can't keep
// Deezer from opening.
static NSString *guardPath(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [caches URLByAppendingPathComponent:@"Deezit" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"player-buttons.placing"].path;
}

static BOOL sPlacedOnce;

static BOOL ownsMethod(Class c, SEL s) {
    if (!c) return NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(c, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == s;
    free(list);
    return found;
}

%group DZPlayerButtonHooks

%hook DZRPlayerTrackActionsController

- (void)updateButtons {
    %orig;
    BOOL first = !sPlacedOnce;
    if (first) [[NSData data] writeToFile:guardPath() atomically:NO];
    @try { placeButtons(self); } @catch (NSException *e) { DZLog("player: couldn't add the buttons: %@", e.reason); }
    if (first) {
        sPlacedOnce = YES;
        [NSFileManager.defaultManager removeItemAtPath:guardPath() error:nil];
    }
}

%end

%end

%group DZPlayerButtonTintHooks

// Deezer's share button changed colour (the cover changed): ours follow.
%hook DZPlayerButtonHookTarget

- (void)setDefaultTintColor:(UIColor *)c {
    %orig;
    NSPointerArray *box = objc_getAssociatedObject(self, kDZShareMirrorKey);
    DZQuickButtons *q = box.count ? (__bridge DZQuickButtons *)[box pointerAtIndex:0] : nil;
    if (q) dispatch_async(dispatch_get_main_queue(), ^{ [q syncLook]; });
}

- (void)updateTintColor {
    %orig;
    NSPointerArray *box = objc_getAssociatedObject(self, kDZShareMirrorKey);
    DZQuickButtons *q = box.count ? (__bridge DZQuickButtons *)[box pointerAtIndex:0] : nil;
    if (q) dispatch_async(dispatch_get_main_queue(), ^{ [q syncLook]; });
}

%end

%end

void DZPlayerButtonsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([NSFileManager.defaultManager fileExistsAtPath:guardPath()]) {
            [NSFileManager.defaultManager removeItemAtPath:guardPath() error:nil];   // try again next launch
            DZLog("player: Deezer closed while Deezit was adding its player buttons last time; not adding them this launch");
            return;
        }
        Class c = objc_getClass("DZRPlayerTrackActionsController");
        if (c && class_getInstanceMethod(c, @selector(updateButtons)) && class_getInstanceMethod(c, @selector(stackView))) {
            %init(DZPlayerButtonHooks);
            Class button = objc_getClass("DZRPlayerButton");
            if (ownsMethod(button, @selector(setDefaultTintColor:)) && ownsMethod(button, @selector(updateTintColor)))
                %init(DZPlayerButtonTintHooks, DZPlayerButtonHookTarget = button);
            else
                DZLog("player: DZRPlayerButton not as expected, the buttons keep their first colour");
        } else {
            DZLog("player: DZRPlayerTrackActionsController not as expected, no quick buttons");
        }
    });
}
