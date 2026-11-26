// Two small changes to Deezer's player screens.
//
// 1. Up next (DZRQueueListViewController, a UITableViewController): Deezer
//    offers Delete on a swipe to the left (its
//    -tableView:trailingSwipeActionsConfigurationForRowAtIndexPath: builds a
//    contextual action that calls -deleteRowInTableView:atIndexPath:). Deezit
//    offers the same action on a swipe to the right.
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
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip;
- (BOOL)canDeleteRowAtIndexPath:(NSIndexPath *)ip;
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

#pragma mark - hooks

%group DZQueueSwipeHooks

%hook DZRQueueListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    holdContentPop(self, YES);
}

// Outside Edit mode Deezer answers "no editing style" for every row
// (canDeleteRowAtIndexPath: && isDeleting), and iOS then shows no swipe
// actions at all. Rows Deezer can delete (canDeleteRowAtIndexPath:: the queue
// is editable and it isn't the song playing) get the delete style, so both
// swipes work; Edit mode keeps Deezer's own answer.
- (UITableViewCellEditingStyle)tableView:(UITableView *)tv editingStyleForRowAtIndexPath:(NSIndexPath *)ip {
    if (!tv.isEditing && [self respondsToSelector:@selector(canDeleteRowAtIndexPath:)] && [self canDeleteRowAtIndexPath:ip])
        return UITableViewCellEditingStyleDelete;
    return %orig;
}

// a swipe to the right: Deezer's own Delete, as on a swipe to the left
%new
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    return [self tableView:tv trailingSwipeActionsConfigurationForRowAtIndexPath:ip];
}

%end

%end

%group DZQueueLeaveHooks

// (Up next doesn't override it: hooked on UIViewController, for the queue only)
%hook UIViewController

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
