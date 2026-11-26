// Two small changes to Deezer's player screens.
//
// 1. Up next (DZRQueueListViewController, a DZRCommonTableViewController):
//    Deezer offers Delete on a swipe to the left only in its delete mode (the
//    bar button that calls -displayDeleteButtons); its
//    -tableView:trailingSwipeActionsConfigurationForRowAtIndexPath: builds a
//    contextual action that calls -deleteRowInTableView:atIndexPath:. Deezit
//    lets every row Deezer can delete be swiped at any time, to the left or to
//    the right.
//
// 2. The artist · album line under the title (DZRPlayerMainViewController):
//    Deezer's -didTapPlayerArtistAlbumButton opens the artist
//    ([self dzrGoToArtist:currentTrack.artist]). Deezit turns that button into
//    a native menu: "Go to <artist>" (each artist when there are several) and
//    "Go to <album>" ([self dzrGoToAlbum:currentTrack.album], the album page
//    Deezer opens elsewhere). If the line isn't a UIButton, the tap shows the
//    same choices as an action sheet instead.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DZLog.h"

@interface DZRQueueListViewController : UIViewController
- (UITableView *)tableView;
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip;
- (BOOL)canDeleteRowAtIndexPath:(NSIndexPath *)ip;
- (BOOL)canEditQueueList;
- (BOOL)isDeleting;
- (NSUInteger)currentTrackIndex;
@end

@interface DZRPlayerMainViewController : UIViewController
- (id)currentTrack;
@end

static void *kDZArtistMenuKey = &kDZArtistMenuKey;   // player VC -> the button that got the menu (weak box)

static id kv(id o, NSString *key) {
    if (!o || ![o respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try { return [o valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSString *str(id v) {
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

#pragma mark - artist · album menu

// The destinations for the track playing now, as (title, symbol, block).
static NSArray<NSArray *> *destinations(UIViewController *vc) {
    if (![vc respondsToSelector:@selector(currentTrack)]) return @[];
    id track = [(DZRPlayerMainViewController *)vc currentTrack];
    NSMutableArray *out = [NSMutableArray array];
    __weak UIViewController *weakVC = vc;

    SEL goArtist = NSSelectorFromString(@"dzrGoToArtist:");
    if ([vc respondsToSelector:goArtist]) {
        NSMutableArray *artists = [NSMutableArray array];
        id list = kv(track, @"artists");
        if ([list isKindOfClass:[NSArray class]] && [list count] > 1) [artists addObjectsFromArray:list];
        else if (kv(track, @"artist")) [artists addObject:kv(track, @"artist")];
        for (id artist in artists) {
            NSString *name = str(kv(artist, @"name")) ?: str(kv(track, @"artistName")) ?: @"artist";
            void (^go)(void) = ^{
                UIViewController *v = weakVC;
                if (v) ((void (*)(id, SEL, id))objc_msgSend)(v, goArtist, artist);
            };
            [out addObject:@[[NSString stringWithFormat:@"Go to “%@”", name], @"person.crop.circle", go]];
        }
    }
    SEL goAlbum = NSSelectorFromString(@"dzrGoToAlbum:");
    id album = kv(track, @"album");
    if (album && [vc respondsToSelector:goAlbum]) {
        NSString *name = str(kv(track, @"albumName")) ?: str(kv(album, @"title")) ?: str(kv(album, @"name")) ?: @"album";
        void (^go)(void) = ^{
            UIViewController *v = weakVC;
            if (v) ((void (*)(id, SEL, id))objc_msgSend)(v, goAlbum, album);
        };
        [out addObject:@[[NSString stringWithFormat:@"Go to “%@”", name], @"square.stack", go]];
    }
    return out;
}

static UIMenu *artistAlbumMenu(UIViewController *vc) {
    __weak UIViewController *weakVC = vc;
    UIDeferredMenuElement *items = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        NSMutableArray *actions = [NSMutableArray array];
        UIViewController *v = weakVC;
        for (NSArray *d in v ? destinations(v) : @[]) {
            void (^go)(void) = d[2];
            [actions addObject:[UIAction actionWithTitle:d[0] image:[UIImage systemImageNamed:d[1]] identifier:nil
                                                 handler:^(UIAction *a) { go(); }]];
        }
        completion(actions);
    }];
    return [UIMenu menuWithChildren:@[items]];
}

// The control whose tap calls -didTapPlayerArtistAlbumButton.
static UIControl *artistAlbumControl(UIViewController *vc) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:vc.view];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UIControl class]]) {
            NSArray *acts = [(UIControl *)v actionsForTarget:vc forControlEvent:UIControlEventTouchUpInside];
            if ([acts containsObject:@"didTapPlayerArtistAlbumButton"]) return (UIControl *)v;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static void installArtistAlbumMenu(UIViewController *vc) {
    if (!vc.isViewLoaded) return;
    NSPointerArray *box = objc_getAssociatedObject(vc, kDZArtistMenuKey);
    UIButton *done = box.count ? [box pointerAtIndex:0] : nil;
    if (done && done.window && done.showsMenuAsPrimaryAction) return;
    UIControl *c = artistAlbumControl(vc);
    if (![c isKindOfClass:[UIButton class]]) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            DZLog("player: artist · album line is %@, its tap shows an action sheet", c ? NSStringFromClass([c class]) : @"not a control");
        }
        return;
    }
    UIButton *b = (UIButton *)c;
    b.menu = artistAlbumMenu(vc);
    b.showsMenuAsPrimaryAction = YES;
    NSPointerArray *nb = [NSPointerArray weakObjectsPointerArray];
    [nb addPointer:(__bridge void *)b];
    objc_setAssociatedObject(vc, kDZArtistMenuKey, nb, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DZLog("player: artist · album line opens a Go to artist / album menu");
}

static void showArtistAlbumSheet(UIViewController *vc) {
    NSArray *dests = destinations(vc);
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *d in dests) {
        void (^go)(void) = d[2];
        [ac addAction:[UIAlertAction actionWithTitle:d[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { go(); }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIControl *c = artistAlbumControl(vc);
    ac.popoverPresentationController.sourceView = c ?: vc.view;
    ac.popoverPresentationController.sourceRect = c ? c.bounds : CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
    [vc presentViewController:ac animated:YES completion:nil];
}

#pragma mark - queue swipes vs. swipe back

// iOS 26 navigation controllers go back on a right swipe anywhere in the
// content (interactiveContentPopGestureRecognizer), which beats a row's
// swipe-right Delete. While Up next is on screen that gesture is off; the
// swipe from the left edge (interactivePopGestureRecognizer) still goes back.
static void *kDZContentPopKey = &kDZContentPopKey;   // queue VC -> @YES when Deezit turned it off

static UIGestureRecognizer *contentPop(UIViewController *vc) {
    UINavigationController *nav = vc.navigationController;
    SEL s = NSSelectorFromString(@"interactiveContentPopGestureRecognizer");
    if (![nav respondsToSelector:s]) return nil;
    id g = ((id (*)(id, SEL))objc_msgSend)(nav, s);
    return [g isKindOfClass:[UIGestureRecognizer class]] ? g : nil;
}

static void holdContentPop(UIViewController *vc, BOOL hold) {
    UIGestureRecognizer *g = contentPop(vc);
    if (!g) return;
    if (hold && g.enabled) {
        g.enabled = NO;
        objc_setAssociatedObject(vc, kDZContentPopKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (!hold && objc_getAssociatedObject(vc, kDZContentPopKey)) {
        g.enabled = YES;
        objc_setAssociatedObject(vc, kDZContentPopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static Class sQueueClass;

static NSString *yesNo(BOOL b) { return b ? @"yes" : @"no"; }

// Pan gestures from the table up to the window, which could take a row's
// swipe (the table's own scroll pan is listed as well).
static NSString *pansAbove(UIView *table) {
    NSMutableArray *out = [NSMutableArray array];
    int depth = 0;
    for (UIView *v = table; v && depth < 16; v = v.superview, depth++) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            NSString *cls = NSStringFromClass([g class]);
            if (![g isKindOfClass:[UIPanGestureRecognizer class]] && [cls rangeOfString:@"Swipe" options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
            [out addObject:[NSString stringWithFormat:@"%@%@ on %@", cls, g.enabled ? @"" : @" (off)",
                            v == table ? @"table" : NSStringFromClass([v class])]];
        }
    }
    return out.count ? [out componentsJoinedByString:@", "] : @"none";
}

// One line when Up next appears (only when it differs from the last one), so
// a log shows whether Deezer allows deleting and what could take the swipe.
static void logQueueState(DZRQueueListViewController *vc) {
    UITableView *tv = [vc respondsToSelector:@selector(tableView)] ? [vc tableView] : nil;
    if (![tv isKindOfClass:[UITableView class]]) {
        DZLog("up next: no table view");
        return;
    }
    NSInteger rows = tv.numberOfSections ? [tv numberOfRowsInSection:0] : 0;
    NSInteger playing = [vc respondsToSelector:@selector(currentTrackIndex)] ? (NSInteger)[vc currentTrackIndex] : -1;
    NSInteger probe = playing + 1 < rows ? playing + 1 : (rows > 0 && playing != 0 ? 0 : -1);
    NSString *row = @"no row besides the playing one";
    if (probe >= 0) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:probe inSection:0];
        BOOL can = [vc canDeleteRowAtIndexPath:ip];
        BOOL offered = [vc tableView:tv trailingSwipeActionsConfigurationForRowAtIndexPath:ip] != nil;
        NSInteger style = [(id<UITableViewDelegate>)vc tableView:tv editingStyleForRowAtIndexPath:ip];
        row = [NSString stringWithFormat:@"row %ld deletable %@, style %ld, Delete offered %@", (long)probe, yesNo(can), (long)style, yesNo(offered)];
    }
    UIGestureRecognizer *pop = contentPop(vc);
    NSString *line = [NSString stringWithFormat:
        @"up next: %ld rows, playing row %ld · queue editable %@, delete mode %@ · %@ · table editing %@, delegate %@, data source %@ · content swipe back %@ · %lu screens deep · pans: %@",
        (long)rows, (long)playing,
        [vc respondsToSelector:@selector(canEditQueueList)] ? yesNo([vc canEditQueueList]) : @"?",
        [vc respondsToSelector:@selector(isDeleting)] ? yesNo([vc isDeleting]) : @"?",
        row, yesNo(tv.isEditing),
        tv.delegate == (id)vc ? @"Up next" : NSStringFromClass([(id)tv.delegate class]),
        tv.dataSource == (id)vc ? @"Up next" : NSStringFromClass([(id)tv.dataSource class]),
        pop ? (pop.enabled ? @"on" : @"off") : @"none",
        (unsigned long)vc.navigationController.viewControllers.count, pansAbove(tv)];
    static NSString *last;
    if ([line isEqualToString:last]) return;
    last = line;
    DZLog("%@", line);
}

#pragma mark - hooks

%group DZQueueSwipeHooks

%hook DZRQueueListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    holdContentPop(self, YES);
}

// Deezer gives a row the delete style only in its own delete mode (its bar
// button's -displayDeleteButtons: canDeleteRowAtIndexPath: && isDeleting), and iOS shows no
// swipe actions on a row without it. Rows Deezer can delete (the queue is
// editable and it isn't the song playing) now always get it. This can't
// depend on tableView.isEditing: iOS turns editing on while a row is being
// swiped, so the old "!isEditing" check took the style away mid-swipe.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    if ([self canDeleteRowAtIndexPath:ip]) return UITableViewCellEditingStyleDelete;
    return %orig;
}

// a swipe to the right: Deezer's own Delete, as on a swipe to the left
%new
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    return [self tableView:tv trailingSwipeActionsConfigurationForRowAtIndexPath:ip];
}

// iOS calls these as a row's swipe actions open and close (Deezer has
// neither); a swipe that never logs "opened" never started
%new
- (void)tableView:(UITableView *)tv willBeginEditingRowAtIndexPath:(NSIndexPath *)ip {
    DZLog("up next: swipe opened on row %ld (deletable %@)", (long)ip.row, yesNo([self canDeleteRowAtIndexPath:ip]));
}

%new
- (void)tableView:(UITableView *)tv didEndEditingRowAtIndexPath:(NSIndexPath *)ip {
    DZLog("up next: swipe closed on row %ld", ip ? (long)ip.row : -1L);
}

%end

%end

%group DZQueueLeaveHooks

// (Up next overrides neither: hooked on UIViewController, for the queue only;
// Deezer's own viewDidAppear: overrides above it call super)
%hook UIViewController

// the push may turn the content swipe back on again as it ends
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (sQueueClass && [self isKindOfClass:sQueueClass]) {
        holdContentPop(self, YES);
        logQueueState((DZRQueueListViewController *)self);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (sQueueClass && [self isKindOfClass:sQueueClass]) holdContentPop(self, NO);
}

%end

%end

%group DZArtistAlbumHooks

%hook DZRPlayerMainViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    installArtistAlbumMenu(self);
}

- (void)setTitleLabelsWithCurrentTrack:(id)track {
    %orig;
    installArtistAlbumMenu(self);
}

- (void)didTapPlayerArtistAlbumButton {
    // only reached when the line isn't a button with our menu
    if (destinations(self).count > 1) {
        showArtistAlbumSheet(self);
        return;
    }
    %orig;
}

%end

%end

static BOOL implements(Class c, SEL s) {
    return c && class_getInstanceMethod(c, s) != NULL;
}

void DZPlayerExtrasInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class queue = objc_getClass("DZRQueueListViewController");
        if (implements(queue, @selector(tableView:trailingSwipeActionsConfigurationForRowAtIndexPath:)) &&
            implements(queue, @selector(tableView:editingStyleForRowAtIndexPath:)) && implements(queue, @selector(canDeleteRowAtIndexPath:))) {
            sQueueClass = queue;
            %init(DZQueueSwipeHooks);
            %init(DZQueueLeaveHooks);
            DZLog("player: up next rows delete on a swipe to the right too");
        } else {
            DZLog("player: DZRQueueListViewController not as expected, no swipe-right delete");
        }
        Class main = objc_getClass("DZRPlayerMainViewController");
        if (implements(main, @selector(didTapPlayerArtistAlbumButton)) && implements(main, @selector(setTitleLabelsWithCurrentTrack:)) &&
            implements(main, @selector(currentTrack))) {
            %init(DZArtistAlbumHooks);
        } else {
            DZLog("player: DZRPlayerMainViewController not as expected, no artist / album menu");
        }
    });
}
