#import "DZDebugViewController.h"
#import "DZIcons.h"
#import "DZDebugLog.h"
#import "DZPrefs.h"
#import "DZAudioHook.h"
#import "DZLockArtwork.h"
#import "DZBufferProbe.h"
#import "DZSeparator.h"
#import "DZAutoMix.h"
#import "DZSettingsEntry.h"
#import "DZLog.h"

#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif

static UIWindow *dzKeyWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

void DZToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = dzKeyWindow();
        if (!w) return;
        UILabel *l = [UILabel new];
        l.text = message;
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont boldSystemFontOfSize:13];
        l.textColor = UIColor.whiteColor;
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        l.layer.cornerRadius = 10;
        l.clipsToBounds = YES;
        l.userInteractionEnabled = NO;
        CGFloat width = MIN(w.bounds.size.width - 32, 360);
        CGSize fit = [l sizeThatFits:CGSizeMake(width - 16, CGFLOAT_MAX)];
        l.frame = CGRectMake((w.bounds.size.width - width) / 2, w.safeAreaInsets.top + 8, width, fit.height + 16);
        [w addSubview:l];
        [UIView animateWithDuration:0.4 delay:2.8 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL done) { [l removeFromSuperview]; }];
    });
}

@interface DZDebugViewController ()
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic) BOOL followTail;
@end

@implementation DZDebugViewController

+ (UIViewController *)presentableController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[DZDebugViewController new]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    return nav;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Deezit debug";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.followTail = YES;

    UITextView *tv = [UITextView new];
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.textColor = UIColor.labelColor;
    tv.backgroundColor = UIColor.systemBackgroundColor;
    tv.textContainerInset = UIEdgeInsetsMake(12, 8, 24, 8);
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    self.textView = tv;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    UIBarButtonItem *share = [[UIBarButtonItem alloc] initWithImage:DZIcon(@"share", @"square.and.arrow.up", 0)
                                                              style:UIBarButtonItemStylePlain target:self action:@selector(share:)];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:DZIcon(@"dotsHorizontal", @"ellipsis.circle", 0) menu:nil];
    self.navigationItem.rightBarButtonItems = @[share, more];
    [self rebuildMenu];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:DZDebugLogChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
                                                 name:DZPrefsChangedNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)rebuildMenu {
    __weak __typeof(self) weakSelf = self;
    BOOL hookOn = DZPrefBool(kDZAudioHook);
    UIAction *settings = [UIAction actionWithTitle:@"Open Deezit settings" image:DZIcon(@"gear", @"gearshape", 0)
                                        identifier:nil handler:^(UIAction *a) {
        [weakSelf.navigationController dismissViewControllerAnimated:YES completion:^{ DZPresentSettings(); }];
    }];
    UIAction *copy = [UIAction actionWithTitle:@"Copy log" image:DZIcon(@"squareDouble", @"doc.on.doc", 0)
                                    identifier:nil handler:^(UIAction *a) {
        UIPasteboard.generalPasteboard.string = [weakSelf fullText];
        DZToast(@"Deezit: log copied");
    }];
    UIAction *clear = [UIAction actionWithTitle:@"Clear log" image:DZIcon(@"trash", @"trash", 0)
                                     identifier:nil handler:^(UIAction *a) {
        DZDebugLogClear();
    }];
    clear.attributes = UIMenuElementAttributesDestructive;
    UIAction *hook = [UIAction actionWithTitle:hookOn ? @"Turn audio hook off (relaunch)" : @"Turn audio hook on (relaunch)"
                                         image:(hookOn ? DZIcon(@"slashCircle", @"bolt.slash", 0) : DZIcon(@"wrench", @"bolt", 0))
                                    identifier:nil handler:^(UIAction *a) {
        BOOL now = !DZPrefBool(kDZAudioHook);
        DZPrefSet(kDZAudioHook, @(now));
        DZLog("debug: audio hook turned %@ (applies after relaunching Deezer)", now ? @"on" : @"off");
        DZToast(now ? @"Audio hook on - relaunch Deezer" : @"Audio hook off - relaunch Deezer");
        [weakSelf rebuildMenu];
    }];
    UIMenu *safety = [UIMenu menuWithTitle:@"If playback breaks, turn the hook off" image:nil identifier:nil
                                   options:UIMenuOptionsDisplayInline children:@[hook]];
    self.navigationItem.rightBarButtonItems.lastObject.menu =
        [UIMenu menuWithTitle:@"" children:@[settings, copy, clear, safety]];
}

- (NSString *)statusHeader {
    NSBundle *b = NSBundle.mainBundle;
    DZAudioParams p = DZPrefsAudioParams();
    return [NSString stringWithFormat:
        @"Deezit %s · %@ %@ (%@) · iOS %@\n"
        @"audio hook: %@\n"
        @"%@\n"
        @"%@\n"
        @"%@\n"
        @"%@\n"
        @"%@\n"
        @"effect: %@ · speed %.2fx · reverb mix %d%% room %d%% damp %d%% · vocals %d%%\n"
        @"gestures: 3-finger double tap = this panel · 3-finger hold = settings\n"
        @"──────────────────────────────────────────\n",
        DEEZIT_VERSION,
        b.bundleIdentifier, [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [b objectForInfoDictionaryKey:@"CFBundleVersion"], UIDevice.currentDevice.systemVersion,
        DZPrefBool(kDZAudioHook) ? @"on" : @"OFF (kill switch)",
        DZAudioStatusSummary(),
        DZLockArtworkStatus(),
        DZBufferProbeStatus(),
        DZSingStatus(),
        DZAutoMixStatus(),
        p.enabled ? @"ON" : @"off", p.speed,
        (int)lroundf(p.reverbMix * 100), (int)lroundf(p.reverbRoom * 100), (int)lroundf(p.reverbDamp * 100),
        (int)lroundf((1.0f - p.vocalCut) * 100)];
}

- (NSString *)fullText {
    return [[self statusHeader] stringByAppendingString:DZDebugLogText()];
}

- (void)reload {
    UITextView *tv = self.textView;
    CGFloat bottom = tv.contentSize.height - tv.bounds.size.height + tv.contentInset.bottom;
    self.followTail = tv.contentOffset.y >= bottom - 40 || tv.contentSize.height <= tv.bounds.size.height;
    tv.text = [self fullText];
    if (self.followTail) {
        [tv layoutIfNeeded];
        [tv scrollRangeToVisible:NSMakeRange(tv.text.length ? tv.text.length - 1 : 0, 1)];
    }
}

- (void)done {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)share:(UIBarButtonItem *)sender {
    // the text (status + this session's ring) pastes well into a chat; the
    // previous session's file is the one that matters after a crash
    NSMutableArray *items = [NSMutableArray arrayWithObject:[self fullText]];
    NSURL *prev = DZDebugLogPreviousFileURL();
    if (prev) [items addObject:prev];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    avc.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:avc animated:YES completion:nil];
}

@end
