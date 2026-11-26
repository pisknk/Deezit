// A "Deezit" card in Deezer's own Settings page.
//
// Deezer's Settings (Deezer.SettingsHostingController, presented from
// DZRRootViewController) is SwiftUI, so its list can't take a real row. Deezit
// puts its own card, drawn in the page's colours (Subscription / Preferences
// style: a section title and a rounded row with an icon and a chevron), under
// the page's content inside its scroll view, and gives the scroll view room
// for it. Tapping it pushes Deezit's settings, in the same colours, onto the
// navigation controller SwiftUI uses for Settings' own pages; without one it
// opens as a sheet. The first time the page appears its view tree is logged,
// to match the look exactly. The three-finger hold still opens the settings.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DZLog.h"
#import "DZIcons.h"
#import "DZSettingsViewController.h"

static void *kDZCardKey = &kDZCardKey;            // settings VC / scroll view -> the card
static void *kDZCardInsetKey = &kDZCardInsetKey;  // scroll view -> its own bottom inset
static const CGFloat kDZHeaderH = 44, kDZRowH = 48, kDZGapAbove = 12, kDZGapBelow = 32;

static UIColor *rgb(int r, int g, int b) { return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1]; }

static UINavigationController *navInside(UIViewController *vc, int depth) {
    if (depth > 6) return nil;
    for (UIViewController *c in vc.childViewControllers) {
        if ([c isKindOfClass:[UINavigationController class]] && c.view.window) return (UINavigationController *)c;
        UINavigationController *n = navInside(c, depth + 1);
        if (n) return n;
    }
    return nil;
}

static void openDeezit(UIViewController *host) {
    if (!host.view.window) return;
    UINavigationController *nav = navInside(host, 0) ?: host.navigationController;
    UIViewController *page = [DZSettingsViewController deezerSettingsPage];
    if (nav) {
        DZLog("settings: Deezit opened from Deezer's Settings (pushed)");
        [nav pushViewController:page animated:YES];
        return;
    }
    UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:page];
    wrap.navigationBarHidden = YES;
    wrap.modalPresentationStyle = UIModalPresentationPageSheet;
    DZLog("settings: Deezit opened from Deezer's Settings (sheet)");
    UIViewController *top = host;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:wrap animated:YES completion:nil];
}

@interface DZDeezitRow : UIControl
@end

@implementation DZDeezitRow

- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = rgb(40, 6, 41);
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        UIColor *secondary = rgb(210, 177, 211);

        UIImageView *icon = [[UIImageView alloc] initWithImage:DZIcon(@"waveform", @"waveform", 0)];
        icon.tintColor = secondary;
        icon.contentMode = UIViewContentModeCenter;
        UILabel *title = [UILabel new];
        title.text = @"Deezit";
        title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        title.textColor = UIColor.whiteColor;
        UIImageView *chevron = [[UIImageView alloc] initWithImage:DZIcon(@"chevronRight", @"chevron.right", 16)];
        chevron.tintColor = secondary;
        for (UIView *v in @[icon, title, chevron]) {
            v.translatesAutoresizingMaskIntoConstraints = NO;
            v.userInteractionEnabled = NO;
            [self addSubview:v];
        }
        [NSLayoutConstraint activateConstraints:@[
            [icon.centerXAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:41],
            [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = @"Deezit";
        self.accessibilityTraits = UIAccessibilityTraitButton;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? rgb(58, 20, 59) : rgb(40, 6, 41);
}

@end

@interface DZDeezitCard : UIView
@property (nonatomic, weak) UIViewController *host;
@end

@implementation DZDeezitCard

- (instancetype)initWithHost:(UIViewController *)host {
    if ((self = [super initWithFrame:CGRectZero])) {
        _host = host;
        UILabel *header = [UILabel new];
        header.text = @"Deezit";
        header.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        header.textColor = rgb(210, 177, 211);
        header.frame = CGRectMake(16, kDZGapAbove, 300, kDZHeaderH - 8);
        [self addSubview:header];
        DZDeezitRow *row = [DZDeezitRow new];
        row.frame = CGRectMake(16, kDZGapAbove + kDZHeaderH, 0, kDZRowH);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:row];
        self.frame = CGRectMake(0, 0, 32, kDZGapAbove + kDZHeaderH + kDZRowH);
        row.frame = CGRectMake(16, kDZGapAbove + kDZHeaderH, 0, kDZRowH);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *v in self.subviews)
        if ([v isKindOfClass:[DZDeezitRow class]]) v.frame = CGRectMake(16, kDZGapAbove + kDZHeaderH, self.bounds.size.width - 32, kDZRowH);
}

- (void)open {
    UIViewController *host = self.host;
    if (host) openDeezit(host);
}

@end

#pragma mark - placing the card

static UIScrollView *mainScrollView(UIView *root) {
    UIScrollView *best = nil;
    CGFloat bestArea = 0;
    CGFloat minW = root.bounds.size.width * 0.9, minH = root.bounds.size.height * 0.4;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[DZDeezitCard class]]) continue;
        if ([v isKindOfClass:[UIScrollView class]] && ![v isKindOfClass:[UITextView class]]) {
            UIScrollView *s = (UIScrollView *)v;
            CGSize b = s.bounds.size;
            if (s.contentSize.width <= b.width + 1 && b.width >= minW && b.height >= minH && b.width * b.height > bestArea) {
                best = s;
                bestArea = b.width * b.height;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// SwiftUI resets the scroll view's insets, so the card makes room by making
// the content itself taller: every content size SwiftUI sets (its own height,
// kept in kDZCardInsetKey) gets the card's height added, and the card sits at
// SwiftUI's height.
static CGFloat cardBlockHeight(void) {
    return kDZGapAbove + kDZHeaderH + kDZRowH + kDZGapBelow;
}

static void layoutCard(UIScrollView *sv, UIView *card) {
    NSNumber *base = objc_getAssociatedObject(sv, kDZCardInsetKey);
    CGFloat swiftUIHeight = base ? base.doubleValue : sv.contentSize.height;
    card.frame = CGRectMake(0, swiftUIHeight, sv.bounds.size.width, kDZGapAbove + kDZHeaderH + kDZRowH);
}

static void dumpViews(UIView *v, int depth, NSMutableString *out, int *budget) {
    if (!v || depth > 12 || *budget <= 0) return;
    (*budget)--;
    CGRect f = v.frame;
    NSString *extra = @"";
    if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *s = (UIScrollView *)v;
        extra = [NSString stringWithFormat:@" content %.0fx%.0f inset %.0f/%.0f", s.contentSize.width, s.contentSize.height,
                 s.adjustedContentInset.top, s.adjustedContentInset.bottom];
    } else if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        extra = [NSString stringWithFormat:@" \"%@\" %@ %.0fpt", l.text, l.font.fontName, l.font.pointSize];
    }
    if (v.backgroundColor) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        [v.backgroundColor getRed:&r green:&g blue:&b alpha:&a];
        extra = [extra stringByAppendingFormat:@" bg %d,%d,%d,%.2f", (int)(r * 255), (int)(g * 255), (int)(b * 255), a];
    }
    if (v.layer.cornerRadius > 0) extra = [extra stringByAppendingFormat:@" radius %.0f", v.layer.cornerRadius];
    [out appendFormat:@"%*s%@ (%.0f,%.0f %.0fx%.0f)%@\n", depth * 2, "", NSStringFromClass([v class]),
                      f.origin.x, f.origin.y, f.size.width, f.size.height, extra];
    for (UIView *sub in v.subviews) dumpViews(sub, depth + 1, out, budget);
}

static BOOL isDeezerSettings(UIViewController *vc) {
    NSString *name = NSStringFromClass([vc class]);
    return [name hasPrefix:@"Deezer."] && [name hasSuffix:@"SettingsHostingController"];
}

static void attachCard(UIViewController *vc, NSString *when) {
    UIScrollView *sv = mainScrollView(vc.view);
    if (!sv) {
        DZLog("settings: no scroll view in Deezer's Settings (%@)", when);
        return;
    }
    DZDeezitCard *card = objc_getAssociatedObject(vc, kDZCardKey);
    if (!card) {
        card = [[DZDeezitCard alloc] initWithHost:vc];
        objc_setAssociatedObject(vc, kDZCardKey, card, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (card.superview != sv) {
        [card removeFromSuperview];
        [sv addSubview:card];
        objc_setAssociatedObject(sv, kDZCardKey, card, OBJC_ASSOCIATION_ASSIGN);
        // re-set SwiftUI's height so the hook below adds the card's
        NSNumber *base = objc_getAssociatedObject(sv, kDZCardInsetKey);
        CGSize size = sv.contentSize;
        sv.contentSize = CGSizeMake(size.width, base ? base.doubleValue : size.height);
        DZLog("settings: Deezit card added to Deezer's Settings (%@, in %@ %.0fx%.0f)", when,
              NSStringFromClass([sv class]), sv.bounds.size.width, sv.bounds.size.height);
    }
    layoutCard(sv, card);
}

%group DZDeezerSettingsHooks

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!isDeezerSettings(self)) return;
    attachCard(self, @"appeared");
    __weak UIViewController *weakSelf = self;
    // SwiftUI can finish its layout a moment later
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *s = weakSelf;
        if (!s) return;
        attachCard(s, @"settled");
        static BOOL dumped;
        if (!dumped) {
            dumped = YES;
            NSMutableString *dump = [NSMutableString string];
            int budget = 140;
            dumpViews(s.view, 1, dump, &budget);
            DZLog("settings: Deezer's Settings view tree:\n%@", dump);
        }
    });
}

%end

%hook UIScrollView

// keeps room for the card under SwiftUI's content, and the card there
- (void)setContentSize:(CGSize)size {
    UIView *card = objc_getAssociatedObject(self, kDZCardKey);
    if (!card || card.superview != self) {
        %orig;
        return;
    }
    objc_setAssociatedObject(self, kDZCardInsetKey, @(size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(CGSizeMake(size.width, size.height + cardBlockHeight()));
    layoutCard(self, card);
}

%end

%end

void DZDeezerSettingsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init(DZDeezerSettingsHooks);
        DZLog("settings: a Deezit card will be added to Deezer's Settings");
    });
}
