// The full-screen player's ••• as a native iOS menu (Settings → Player →
// Native ••• menu).
//
// Found in Deezer 11.27.0 (docs/ANALYSIS.md + the probe log):
//   - the full-screen player is DZRPlayerViewController > UINavigationController
//     > DZRPlayerMainViewController (ObjC)
//   - DZRPlayerMainViewController has contextMenuButtonItem (the •••) and the
//     ObjC method displayContextMenu:
//   - the menu is Deezer.BottomSheetNavigationViewController whose root is
//     Deezer.TrackContextMenuController: a plain UIKit UITableView it feeds
//     itself, rows are Deezer.ContextMenuActionTableViewCell (ObjC getters
//     actionText / actionImage / displaysChevron).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DZLog.h"
#import "DZIcons.h"
#import "DZPrefs.h"

@interface DZRPlayerMainViewController : UIViewController
- (void)displayContextMenu:(id)sender;
@end

static Class sTrackMenuClass;               // Deezer.TrackContextMenuController, if readable

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

#pragma mark - native ••• menu
//
// With Settings → Player → Native ••• menu on, the ••• (Deezer's
// contextMenuButtonItem, a UIBarButtonItem calling -displayContextMenu:) gets
// a UIMenu instead of its action. When it opens, Deezit asks Deezer for its
// menu as before (-displayContextMenu:), but takes the sheet Deezer is about
// to present instead of showing it, loads it off screen and reads its rows
// (Deezer.ContextMenuActionTableViewCell: actionText, actionImage,
// displaysChevron). The native menu lists Deezer's rows and the song's
// artists (the sheet's header had them). Choosing a row:
//   - with a chevron (it opens a page, e.g. Add to Playlist): Deezer's sheet
//     is presented as Deezer would have, and the row is selected in it;
//   - without: the row is selected in the sheet off screen. Whatever it then
//     presents is shown from the player, and a dismiss of the never-shown
//     sheet just runs its completion.

static void (^sCapture)(UIViewController *presenter, UIViewController *vc);
static BOOL sBypass;                          // our own presentation of Deezer's sheet
static __weak UIViewController *sNativePlayer;
static __weak UIViewController *sDetachedPresenter;   // who Deezer meant to present the sheet from
static void *kDZDetachedKey = &kDZDetachedKey;   // Deezer's sheet, read but not shown
static void *kDZNativeItemKey = &kDZNativeItemKey; // ••• item -> its original action (when the menu is on)

static BOOL nativeMenuOn(void) {
    return DZPrefBool(kDZNativeMenu) && sTrackMenuClass != Nil;
}

static BOOL isDetached(UIViewController *vc) {
    for (UIViewController *v = vc; v; v = v.parentViewController)
        if (objc_getAssociatedObject(v, kDZDetachedKey)) return YES;
    return NO;
}

static void setDetached(UIViewController *vc, BOOL on) {
    objc_setAssociatedObject(vc, kDZDetachedKey, on ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([vc isKindOfClass:[UINavigationController class]])
        for (UIViewController *c in ((UINavigationController *)vc).viewControllers)
            objc_setAssociatedObject(c, kDZDetachedKey, on ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIViewController *topOf(UIViewController *vc) {
    UIViewController *top = vc;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) top = top.presentedViewController;
    return top;
}

static id kvo(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

@interface DZMenuContext : NSObject
@property (nonatomic, strong) UIViewController *sheet;   // what Deezer presents
@property (nonatomic, strong) UIViewController *menu;    // Deezer.TrackContextMenuController
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, strong) UITableView *table;
@end
@implementation DZMenuContext
@end

static void showSheet(DZMenuContext *ctx, void (^then)(void)) {
    UIViewController *presenter = ctx.presenter.view.window ? ctx.presenter : topOf(sNativePlayer);
    if (!presenter) return;
    setDetached(ctx.sheet, NO);
    sBypass = YES;
    [presenter presentViewController:ctx.sheet animated:YES completion:then];
    sBypass = NO;
}

// Every row runs in Deezer's unseen sheet. A row that opens a page pushes it
// inside the sheet (Add to Playlist, Share… have no chevron, so it can't be
// told in advance): the push hook below then shows the sheet on that page.
static void runRow(DZMenuContext *ctx, NSIndexPath *ip, BOOL opensPage, NSString *title) {
    UITableView *tv = ctx.table;
    id<UITableViewDelegate> d = tv.delegate;
    if (![d respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return;
    DZLog("menu: native menu → \"%@\"%@", title, opensPage ? @" (chevron)" : @"");
    sDetachedPresenter = ctx.presenter;
    [d tableView:tv didSelectRowAtIndexPath:ip];
}

static NSString *rowTitle(UITableViewCell *cell) {
    id t = kvo(cell, @"actionText");
    if ([t isKindOfClass:[NSAttributedString class]]) t = [t string];
    if (![t isKindOfClass:[NSString class]] || ![t length]) t = cell.accessibilityLabel;
    return [t isKindOfClass:[NSString class]] && [t length] ? t : nil;
}

static NSArray<UIMenuElement *> *deezerRows(DZMenuContext *ctx) {
    UITableView *tv = ctx.table;
    id<UITableViewDataSource> ds = tv.dataSource;
    if (!ds) return @[];
    NSInteger sections = [ds respondsToSelector:@selector(numberOfSectionsInTableView:)] ? [ds numberOfSectionsInTableView:tv] : 1;
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger s = 0; s < sections; s++) {
        NSInteger rows = [ds tableView:tv numberOfRowsInSection:s];
        for (NSInteger r = 0; r < rows && r < 40; r++) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
            UITableViewCell *cell = nil;
            @try { cell = [ds tableView:tv cellForRowAtIndexPath:ip]; } @catch (NSException *e) { cell = nil; }
            NSString *title = rowTitle(cell);
            if (!title) continue;
            id image = kvo(cell, @"actionImage");
            BOOL opensPage = [kvo(cell, @"displaysChevron") boolValue];
            [out addObject:[UIAction actionWithTitle:title image:[image isKindOfClass:[UIImage class]] ? image : nil identifier:nil
                                             handler:^(UIAction *a) { runRow(ctx, ip, opensPage, title); }]];
        }
    }
    return out;
}

// The song's artists, which Deezer's sheet showed in its header.
static NSArray<UIMenuElement *> *artistItems(UIViewController *player, NSArray<UIMenuElement *> *deezer) {
    SEL go = NSSelectorFromString(@"dzrGoToArtist:");
    if (![player respondsToSelector:go]) return @[];
    id track = kvo(player, @"currentTrack");
    NSMutableArray *artists = [NSMutableArray array];
    id list = kvo(track, @"artists");
    if ([list isKindOfClass:[NSArray class]] && [list count]) [artists addObjectsFromArray:list];
    else if (kvo(track, @"artist")) [artists addObject:kvo(track, @"artist")];
    NSMutableArray *out = [NSMutableArray array];
    __weak UIViewController *weakPlayer = player;
    for (id artist in artists) {
        NSString *name = kvo(artist, @"name");
        if (![name isKindOfClass:[NSString class]] || !name.length) continue;
        BOOL dup = NO;
        for (UIMenuElement *e in deezer) dup = dup || [e.title containsString:name];
        if (dup) continue;
        [out addObject:[UIAction actionWithTitle:[NSString stringWithFormat:@"Go to “%@”", name]
                                           image:DZIcon(@"human", @"person.crop.circle", 0) identifier:nil
                                         handler:^(UIAction *a) {
            UIViewController *p = weakPlayer;
            if (p) ((void (*)(id, SEL, id))objc_msgSend)(p, go, artist);
        }]];
    }
    return out;
}

static UIMenu *inlineMenu(NSArray<UIMenuElement *> *children) {
    return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:children];
}

// Deezer's sheet, taken instead of presented: read its rows (they can fill in
// a moment after the view loads).
static void readSheet(UIViewController *presenter, UIViewController *vc, void (^finish)(NSArray *, DZMenuContext *)) {
    UIViewController *root = [vc isKindOfClass:[UINavigationController class]]
        ? ((UINavigationController *)vc).viewControllers.firstObject : vc;
    DZMenuContext *ctx = [DZMenuContext new];
    ctx.sheet = vc;
    ctx.menu = root;
    ctx.presenter = presenter;
    if (!sTrackMenuClass || ![root isKindOfClass:sTrackMenuClass]) {
        DZLog("menu: Deezer's ••• gave %@, not its track menu", namesOf(vc));
        finish(nil, ctx);
        return;
    }
    setDetached(vc, YES);
    [vc loadViewIfNeeded];
    [root loadViewIfNeeded];
    UITableView *tv = kvo(root, @"tableView");
    if (![tv isKindOfClass:[UITableView class]]) {
        DZLog("menu: Deezer's track menu has no table");
        finish(nil, ctx);
        return;
    }
    ctx.table = tv;
    __block void (^attempt)(int);
    __weak __block void (^weakAttempt)(int);
    weakAttempt = attempt = ^(int n) {
        NSArray *rows = deezerRows(ctx);
        if (rows.count || n >= 12) {
            finish(rows, ctx);
            return;
        }
        if (n == 4) {
            // some menus fill their rows when they appear
            [vc beginAppearanceTransition:YES animated:NO];
            [vc endAppearanceTransition];
        }
        void (^next)(int) = weakAttempt;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (next) next(n + 1);
        });
    };
    attempt(0);
}

static void collectMenu(UIViewController *player, void (^completion)(NSArray<UIMenuElement *> *)) {
    __block BOOL finished = NO;
    void (^finish)(NSArray *, DZMenuContext *) = ^(NSArray *rows, DZMenuContext *ctx) {
        if (finished) return;
        finished = YES;
        NSMutableArray *all = [NSMutableArray array];
        if (rows.count) {
            [all addObject:inlineMenu(rows)];
            DZLog("menu: native menu with %lu of Deezer's rows", (unsigned long)rows.count);
        } else {
            // couldn't read it: offer Deezer's own sheet
            [all addObject:[UIAction actionWithTitle:@"More…" image:DZIcon(@"dotsHorizontal", @"ellipsis.circle", 0) identifier:nil
                                             handler:^(UIAction *a) {
                if (ctx.sheet) showSheet(ctx, nil);
            }]];
        }
        NSArray *artists = artistItems(player, rows);
        if (artists.count) [all addObject:inlineMenu(artists)];
        completion(all);
    };
    sNativePlayer = player;
    sCapture = ^(UIViewController *presenter, UIViewController *vc) {
        readSheet(presenter, vc, finish);
    };
    UIBarButtonItem *item = kvo(player, @"contextMenuButtonItem");
    @try {
        [(DZRPlayerMainViewController *)player displayContextMenu:item];
    } @catch (NSException *e) {
        DZLog("menu: displayContextMenu: threw %@", e.reason);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished) return;
        sCapture = nil;
        DZLog("menu: Deezer's menu didn't come within 2 s");
        finish(nil, nil);
    });
}

static UIMenu *nativeMenu(UIViewController *player) {
    __weak UIViewController *weakPlayer = player;
    UIDeferredMenuElement *el = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        UIViewController *p = weakPlayer;
        if (p) collectMenu(p, completion);
        else completion(@[]);
    }];
    return [UIMenu menuWithChildren:@[el]];
}

// Puts the native menu on the ••• (or gives the ••• its action back).
static void applyNativeMenu(UIViewController *player) {
    UIBarButtonItem *item = kvo(player, @"contextMenuButtonItem");
    if (![item isKindOfClass:[UIBarButtonItem class]]) return;
    NSString *saved = objc_getAssociatedObject(item, kDZNativeItemKey);
    if (nativeMenuOn()) {
        if (saved && item.menu) return;
        if (!saved) objc_setAssociatedObject(item, kDZNativeItemKey, item.action ? NSStringFromSelector(item.action) : @"displayContextMenu:",
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        item.target = nil;
        item.action = NULL;
        item.menu = nativeMenu(player);
        DZLog("menu: ••• opens a native menu");
    } else if (saved) {
        item.menu = nil;
        item.target = player;
        item.action = NSSelectorFromString(saved);
        objc_setAssociatedObject(item, kDZNativeItemKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DZLog("menu: ••• opens Deezer's sheet again");
    }
}

#pragma mark - hooks

%group DZPlayerMenuTapHooks

%hook DZRPlayerMainViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    sNativePlayer = self;
    applyNativeMenu(self);
}

%end

%end

%group DZPlayerMenuPresentHooks

%hook UIViewController

- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (sBypass) {
        %orig;
        return;
    }
    // the native menu asked Deezer for its sheet: take it instead of showing it
    if (sCapture && vc && isInPlayer(self)) {
        void (^capture)(UIViewController *, UIViewController *) = sCapture;
        sCapture = nil;
        capture(self, vc);
        return;
    }
    // a row run from the native menu presents from Deezer's unseen sheet: show it from the player
    if (vc && isDetached(self) && !self.view.window) {
        UIViewController *top = topOf(sNativePlayer);
        if (top) {
            DZLog("menu: %@ shown from the player", namesOf(vc));
            [top presentViewController:vc animated:animated completion:completion];
            return;
        }
    }
    %orig;
}

// Deezer's never-shown sheet closing itself before running a row's action
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    if (isDetached(self) && !self.presentingViewController && !self.presentedViewController) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    %orig;
}

%end

%hook UINavigationController

// A row of the native menu opened a page inside Deezer's unseen sheet: show
// the sheet, already on that page.
- (void)pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    if (!vc || !isDetached(self) || self.view.window) {
        %orig;
        return;
    }
    UIViewController *sheet = self;
    while (sheet.parentViewController) sheet = sheet.parentViewController;
    %orig(vc, NO);
    UIViewController *presenter = sDetachedPresenter.view.window ? sDetachedPresenter : topOf(sNativePlayer);
    if (!presenter || sheet.presentingViewController) return;
    DZLog("menu: the row opened %@, showing Deezer's sheet on it", NSStringFromClass([vc class]));
    setDetached(sheet, NO);
    sBypass = YES;
    [presenter presentViewController:sheet animated:YES completion:nil];
    sBypass = NO;
}

%end

%end

void DZPlayerMenuInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!objc_getClass("DZRPlayerMainViewController") || !objc_getClass("DZRPlayerViewController")) {
            DZLog("menu: Deezer's player classes not found, no native ••• menu");
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
        } else {
            DZLog("menu: Deezer.TrackContextMenuController not as expected, no native ••• menu");
        }
        // the Native ••• menu switch: apply it to the player right away
        [[NSNotificationCenter defaultCenter] addObserverForName:DZPrefsChangedNotification object:nil
                                                           queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            UIViewController *p = sNativePlayer;
            if (p) applyNativeMenu(p);
        }];
    });
}
