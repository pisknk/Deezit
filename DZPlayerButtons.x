// Slowed + Reverb, Karaoke Mode and AutoMix buttons in the full-screen
// player's action row, next to Share.
//
// Found in Deezer 11.27.0: the row under the cover is
// DZRPlayerTrackActionsController (ObjC-visible): a stackView holding
// shareButton, a spacer, addToPlaylistButton, likeButton (and dislike /
// download / ban in some contexts). -updateButtons takes the arranged views
// out and puts back the ones the current track needs. The buttons are
// DZRPlayerButton (a UIButton): -initWithImage:target:action:, +defaultSize,
// and -setActive:, which shows a small dot under the icon.
//
// After every -updateButtons the three buttons go back in right after Share.
// Tap: turns the feature on / off (the dot shows it's on). Touch and hold:
// its sheet (Playback Controls; Karaoke Mode; AutoMix's switch is in Playback
// Controls).

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

static NSString *quickSymbol(DZQuick q) {
    switch (q) {
        case DZQuickEffect: return @"waveform";
        case DZQuickKaraoke: return @"music.mic";
        default: return @"arrow.triangle.merge";
    }
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
@end

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
        for (NSInteger q = 0; q < DZQuickCount; q++) {
            UIImage *img = [UIImage systemImageNamed:quickSymbol(q)
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightRegular]];
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

- (void)refresh {
    SEL active = NSSelectorFromString(@"setActive:");
    for (UIButton *b in self.buttons) {
        BOOL on = quickIsOn(b.tag);
        if ([b respondsToSelector:active]) ((void (*)(id, SEL, BOOL))objc_msgSend)(b, active, on);
        b.accessibilityValue = on ? @"On" : @"Off";
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
        } else {
            DZLog("player: DZRPlayerTrackActionsController not as expected, no quick buttons");
        }
    });
}
