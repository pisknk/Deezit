// "Playback Controls" row in the full-screen player's ••• menu.
//
// Found in Deezer 11.27.0 (docs/ANALYSIS.md + the probe log):
//   - the full-screen player is DZRPlayerViewController > UINavigationController
//     > DZRPlayerMainViewController (ObjC)
//   - DZRPlayerMainViewController has contextMenuButtonItem (the •••) and the
//     ObjC methods displayContextMenu: / showContextMenuFor:
//   - the menu is Deezer.BottomSheetNavigationViewController whose root is
//     Deezer.TrackContextMenuController: a plain UIKit UITableView it feeds
//     itself (ObjC-visible tableView:numberOfRowsInSection: /
//     cellForRowAtIndexPath: / didSelectRowAtIndexPath:), one section, rows
//     are Deezer.ContextMenuActionTableViewCell (40 pt, ObjC setters
//     setActionText: / setActionImage: / setDisplaysChevron:).
//
// So: a ••• tap is noted, the menu presented right after it from the player
// is recognised in -presentViewController:animated:completion: and flagged,
// and its data source then reports one extra row: row 0 is Playback
// Controls (one of Deezer's own cells), rows 1... are Deezer's rows shifted
// back by one. Tapping it dismisses the menu and opens Deezit's controls as a
// half-height sheet.
//
// Fallback, if TrackContextMenuController changes: a UIKit row styled like
// Deezer's placed under the sheet's list (inside its scroll view). If nothing
// matches at all, nothing is added and the reason is in the debug log.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DZLog.h"
#import "DZSettingsViewController.h"

@interface DZRPlayerMainViewController : UIViewController
@end
// placeholder for Deezer.TrackContextMenuController (a Swift class name with a
// dot can't be written in %hook; %init binds it to the real class)
@interface DZTrackMenu : UIViewController
@end

static CFTimeInterval sMenuTapAt;           // last ••• tap in the player
static Class sTrackMenuClass;               // Deezer.TrackContextMenuController, if hookable
static void *kDZMenuFlagKey = &kDZMenuFlagKey; // menu controller -> @YES: show our row first
static void *kDZCellKey = &kDZCellKey;      // table -> our row-0 cell
static UITableView *sFwdTable;              // set while Deezer builds a shifted row
static NSIndexPath *sFwdRequested;          // the index path the table actually asked for
static BOOL sDumpedHierarchy;               // one view dump per session
static void *kDZRowKey = &kDZRowKey;        // sheet VC -> row, and scroll view -> row
static void *kDZBaseInsetKey = &kDZBaseInsetKey;
static const CGFloat kDZRowHeight = 44;

#pragma mark - row view

@interface DZMenuRow : UIControl
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation DZMenuRow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3" withConfiguration:cfg]];
        icon.tintColor = UIColor.labelColor;
        icon.contentMode = UIViewContentModeCenter;
        icon.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *label = [UILabel new];
        label.text = @"Playback Controls";
        label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        label.textColor = UIColor.labelColor;
        label.translatesAutoresizingMaskIntoConstraints = NO;

        [self addSubview:icon];
        [self addSubview:label];
        // matches the menu's rows: icon centred ~36 pt from the edge, text at ~65 pt
        [NSLayoutConstraint activateConstraints:@[
            [icon.centerXAnchor constraintEqualToAnchor:self.leadingAnchor constant:36],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:28],
            [label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:65],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
        self.accessibilityLabel = @"Playback Controls";
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.isAccessibilityElement = YES;
        [self addTarget:self action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? UIColor.tertiarySystemFillColor : UIColor.clearColor;
}

- (void)fire {
    if (self.onTap) self.onTap();
}

@end

#pragma mark - helpers

static BOOL isInPlayer(UIViewController *vc) {
    Class player = objc_getClass("DZRPlayerViewController");
    if (!player) return NO;
    int guard = 0;
    for (UIViewController *v = vc; v && guard < 16; guard++) {
        if ([v isKindOfClass:player]) return YES;
        v = v.parentViewController ?: v.presentingViewController;
    }
    return NO;
}

static NSString *namesOf(UIViewController *vc) {
    NSMutableArray *n = [NSMutableArray arrayWithObject:NSStringFromClass([vc class])];
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *root = ((UINavigationController *)vc).viewControllers.firstObject;
        if (root) [n addObject:NSStringFromClass([root class])];
    }
    return [n componentsJoinedByString:@" / "];
}

static void dumpViews(UIView *v, int depth, NSMutableString *out, int *budget) {
    if (!v || depth > 9 || *budget <= 0) return;
    (*budget)--;
    CGRect f = v.frame;
    NSString *extra = @"";
    if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *s = (UIScrollView *)v;
        extra = [NSString stringWithFormat:@" content %.0fx%.0f inset %.0f/%.0f", s.contentSize.width, s.contentSize.height,
                 s.adjustedContentInset.top, s.adjustedContentInset.bottom];
    }
    [out appendFormat:@"%*s%@ (%.0f,%.0f %.0fx%.0f)%@\n", depth * 2, "", NSStringFromClass([v class]),
                      f.origin.x, f.origin.y, f.size.width, f.size.height, extra];
    for (UIView *sub in v.subviews) dumpViews(sub, depth + 1, out, budget);
}

// The menu's list: the biggest vertically-scrolling scroll view that spans the
// sheet (the artists row in the header is a small horizontal one).
static UIScrollView *menuScrollView(UIView *root) {
    UIScrollView *best = nil;
    CGFloat bestArea = 0;
    CGFloat minW = root.bounds.size.width * 0.9, minH = root.bounds.size.height * 0.3;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[DZMenuRow class]]) continue;
        if ([v isKindOfClass:[UIScrollView class]] && ![v isKindOfClass:[UITextView class]]) {
            UIScrollView *s = (UIScrollView *)v;
            CGSize b = s.bounds.size;
            BOOL horizontal = s.contentSize.width > b.width + 1;
            if (!horizontal && b.width >= minW && b.height >= minH && b.width * b.height > bestArea) {
                best = s;
                bestArea = b.width * b.height;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// Put the row right under the list's content, and give the scroll view room
// for it. Called again whenever the list's content size changes.
static void layoutRowInScrollView(UIScrollView *sv, DZMenuRow *row) {
    row.frame = CGRectMake(0, sv.contentSize.height, sv.bounds.size.width, kDZRowHeight);
    NSNumber *base = objc_getAssociatedObject(sv, kDZBaseInsetKey);
    if (!base) {
        base = @(sv.contentInset.bottom);
        objc_setAssociatedObject(sv, kDZBaseInsetKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIEdgeInsets in = sv.contentInset;
    CGFloat want = base.doubleValue + kDZRowHeight;
    if (fabs(in.bottom - want) > 0.5) {
        in.bottom = want;
        sv.contentInset = in;
    }
}

static void placeRow(UIViewController *sheet, NSString *when) {
    DZMenuRow *row = objc_getAssociatedObject(sheet, kDZRowKey);
    UIView *root = sheet.view;
    if (!row || !root.window) return;

    UIScrollView *sv = menuScrollView(root);
    if (sv) {
        if (row.superview != sv) {
            [row removeFromSuperview];
            row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [sv addSubview:row];
            objc_setAssociatedObject(sv, kDZRowKey, row, OBJC_ASSOCIATION_ASSIGN);
        }
        layoutRowInScrollView(sv, row);
        DZLog("menu: Playback Controls row under the list (%@): y %.0f in %@ %.0fx%.0f", when,
              row.frame.origin.y, NSStringFromClass([sv class]), sv.bounds.size.width, sv.bounds.size.height);
        return;
    }

    // No scrolling list: pin the row to the bottom of the sheet, above the
    // home indicator. Logged, because it can overlap a long menu.
    if (row.superview != root) {
        [row removeFromSuperview];
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [root addSubview:row];
    }
    CGFloat bottom = root.bounds.size.height - root.safeAreaInsets.bottom;
    row.frame = CGRectMake(0, bottom - kDZRowHeight - 8, root.bounds.size.width, kDZRowHeight);
    DZLog("menu: no list scroll view found (%@), row pinned to the sheet bottom", when);
}

// Closes the ••• menu, then opens Deezit's controls over the player.
static void openPlaybackControls(UIViewController *menu) {
    UIViewController *sheet = menu.navigationController ?: menu;
    while (sheet.parentViewController) sheet = sheet.parentViewController;
    UIViewController *presenter = sheet.presentingViewController;
    DZLog("menu: Playback Controls tapped");
    [sheet dismissViewControllerAnimated:YES completion:^{
        UIViewController *pc = [DZSettingsViewController playbackControlsController];
        if (presenter.view.window) [presenter presentViewController:pc animated:YES completion:nil];
    }];
}

static void attachRow(UIViewController *sheet) {
    if (objc_getAssociatedObject(sheet, kDZRowKey)) return;
    DZMenuRow *row = [[DZMenuRow alloc] initWithFrame:CGRectZero];
    __weak UIViewController *weakSheet = sheet;
    row.onTap = ^{
        UIViewController *s = weakSheet;
        if (s) openPlaybackControls(s);
    };
    objc_setAssociatedObject(sheet, kDZRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    placeRow(sheet, @"presented");
    // SwiftUI can finish laying out the list a moment later
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *s = weakSheet;
        if (s) placeRow(s, @"settled");
        if (s && !sDumpedHierarchy) {
            sDumpedHierarchy = YES;
            NSMutableString *dump = [NSMutableString string];
            int budget = 90;
            dumpViews(s.view, 1, dump, &budget);
            DZLog("menu: sheet view hierarchy (%@):\n%@", namesOf(s), dump);
        }
    });
}

#pragma mark - first row in Deezer's own menu table

// Row 0 of the menu: one of Deezer's own ContextMenuActionTableViewCell, set up
// through its ObjC setters so font, icon size and spacing match the other rows
// exactly. Falls back to a plain cell holding DZMenuRow if that class changes.
static UITableViewCell *playbackCell(UITableView *tv) {
    UITableViewCell *cell = objc_getAssociatedObject(tv, kDZCellKey);
    if (cell) return cell;
    UIImage *icon = [[UIImage systemImageNamed:@"slider.horizontal.3"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightRegular]]
                     imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    Class cls = NSClassFromString(@"Deezer.ContextMenuActionTableViewCell");
    SEL setText = NSSelectorFromString(@"setActionText:");
    SEL setImage = NSSelectorFromString(@"setActionImage:");
    SEL setChevron = NSSelectorFromString(@"setDisplaysChevron:");
    if (cls && [cls isSubclassOfClass:[UITableViewCell class]] &&
        [cls instancesRespondToSelector:setText] && [cls instancesRespondToSelector:setImage]) {
        @try {
            cell = [[cls alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"DeezitPlaybackControls"];
            ((void (*)(id, SEL, id))objc_msgSend)(cell, setText, @"Playback Controls");
            ((void (*)(id, SEL, id))objc_msgSend)(cell, setImage, icon);
            if ([cell respondsToSelector:setChevron]) ((void (*)(id, SEL, BOOL))objc_msgSend)(cell, setChevron, NO);
        } @catch (NSException *ex) {
            DZLog("menu: Deezer's menu cell refused setup (%@), using Deezit's own", ex.reason);
            cell = nil;
        }
    }
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"DeezitPlaybackControls"];
        cell.backgroundColor = UIColor.clearColor;
        DZMenuRow *row = [[DZMenuRow alloc] initWithFrame:CGRectZero];
        row.userInteractionEnabled = NO;   // the table handles the tap
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
            [row.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    cell.accessibilityLabel = @"Playback Controls";
    objc_setAssociatedObject(tv, kDZCellKey, cell, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cell;
}

static BOOL showsOurRow(id menu) {
    return objc_getAssociatedObject(menu, kDZMenuFlagKey) != nil;
}

static NSIndexPath *deezerPath(NSIndexPath *ip) {
    return [NSIndexPath indexPathForRow:ip.row - 1 inSection:ip.section];
}

#pragma mark - hooks

// Deezer's menu table, only for menus opened from the player's •••: one extra
// row at the top; every other row is handed to Deezer shifted back by one, so
// its actions still map to the right rows.
%group DZTrackMenuHooks

%hook DZTrackMenu

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    NSInteger n = %orig;
    return (section == 0 && showsOurRow(self)) ? n + 1 : n;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0 || !showsOurRow(self)) return %orig;
    if (ip.row == 0) return playbackCell(tv);
    UITableView *prevTable = sFwdTable;
    NSIndexPath *prevPath = sFwdRequested;
    sFwdTable = tv;
    sFwdRequested = ip;
    UITableViewCell *cell = %orig(tv, deezerPath(ip));
    sFwdTable = prevTable;
    sFwdRequested = prevPath;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section != 0 || !showsOurRow(self)) {
        %orig;
        return;
    }
    if (ip.row == 0) {
        [tv deselectRowAtIndexPath:ip animated:YES];
        openPlaybackControls(self);
        return;
    }
    %orig(tv, deezerPath(ip));
    // Deezer deselects the path it was given, i.e. the row above the tapped one
    [tv deselectRowAtIndexPath:ip animated:YES];
}

%end

%hook UITableView

// While Deezer builds a shifted row it dequeues for its own (shifted) index
// path; hand UIKit the path it actually asked for.
- (UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)ip {
    if (self == sFwdTable && sFwdRequested && ip.section == sFwdRequested.section &&
        ip.row == sFwdRequested.row - 1) {
        return %orig(identifier, sFwdRequested);
    }
    return %orig;
}

%end

%end

%group DZPlayerMenuTapHooks

%hook DZRPlayerMainViewController

- (void)displayContextMenu:(id)sender {
    sMenuTapAt = CACurrentMediaTime();
    DZLog("menu: ••• tapped (displayContextMenu:)");
    %orig;
}

- (void)showContextMenuFor:(id)object {
    sMenuTapAt = CACurrentMediaTime();
    DZLog("menu: showContextMenuFor: %@", NSStringFromClass([object class]));
    %orig;
}

%end

%end

%group DZPlayerMenuPresentHooks

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (!vc || !isInPlayer(self) || [vc isKindOfClass:[UIAlertController class]] ||
        [vc isKindOfClass:[UIActivityViewController class]] || [vc isKindOfClass:[DZSettingsViewController class]]) {
        %orig;
        return;
    }
    NSString *names = namesOf(vc);
    BOOL recentTap = sMenuTapAt > 0 && CACurrentMediaTime() - sMenuTapAt < 2.0;
    BOOL looksLikeTrackMenu = [names rangeOfString:@"TrackBottomSheet"].location != NSNotFound;
    DZLog("menu: player presents %@ (••• tapped just before: %@)", names, recentTap ? @"yes" : @"no");
    if (!recentTap && !looksLikeTrackMenu) {
        %orig;
        return;
    }
    sMenuTapAt = 0;

    // Deezer's track menu: make Playback Controls its first row
    UIViewController *root = [vc isKindOfClass:[UINavigationController class]]
        ? ((UINavigationController *)vc).viewControllers.firstObject : vc;
    if (sTrackMenuClass && [root isKindOfClass:sTrackMenuClass]) {
        objc_setAssociatedObject(root, kDZMenuFlagKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (root.isViewLoaded) {
            // its table may already have loaded without our row
            @try {
                id tv = [root valueForKey:@"tableView"];
                if ([tv isKindOfClass:[UITableView class]]) [(UITableView *)tv reloadData];
            } @catch (NSException *ex) {
                DZLog("menu: couldn't reload the menu table: %@", ex.reason);
            }
        }
        DZLog("menu: Playback Controls added as the first option");
        %orig;
        return;
    }

    // any other sheet: fall back to a row under its list
    __weak UIViewController *weakVC = vc;
    void (^wrapped)(void) = ^{
        if (completion) completion();
        UIViewController *sheet = weakVC;
        if (sheet) attachRow(sheet);
    };
    %orig(vc, animated, wrapped);
}

%end

%hook UIScrollView

// keeps the row under the list when SwiftUI resizes it
- (void)setContentSize:(CGSize)size {
    %orig;
    DZMenuRow *row = objc_getAssociatedObject(self, kDZRowKey);
    if (row && row.superview == self) layoutRowInScrollView(self, row);
}

%end

%end

void DZPlayerMenuInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!objc_getClass("DZRPlayerMainViewController") || !objc_getClass("DZRPlayerViewController")) {
            DZLog("menu: Deezer's player classes not found, no Playback Controls row");
            return;
        }
        %init(DZPlayerMenuTapHooks);
        %init(DZPlayerMenuPresentHooks);

        // Swift class: the runtime resolves the dotted name; the mangled one is the fallback
        Class menu = NSClassFromString(@"Deezer.TrackContextMenuController")
                     ?: objc_getClass("_TtC6Deezer26TrackContextMenuController");
        SEL need[] = { @selector(tableView:numberOfRowsInSection:), @selector(tableView:cellForRowAtIndexPath:),
                       @selector(tableView:didSelectRowAtIndexPath:) };
        BOOL ok = menu != Nil;
        for (size_t i = 0; ok && i < sizeof(need) / sizeof(need[0]); i++) {
            // must be implemented by the class itself, not inherited
            Method m = class_getInstanceMethod(menu, need[i]);
            ok = m && class_getInstanceMethod(class_getSuperclass(menu), need[i]) != m;
        }
        if (ok) {
            sTrackMenuClass = menu;
            %init(DZTrackMenuHooks, DZTrackMenu = menu);
            DZLog("menu: Playback Controls will be the first option of the player's ••• menu");
        } else {
            DZLog("menu: Deezer.TrackContextMenuController not as expected, Playback Controls goes under the menu instead");
        }
    });
}
