// Two small changes to Deezer's player screens.
//
// 1. Up next (DZRQueueListViewController, a DZRCommonTableViewController):
//    its table stays in editing mode for the reorder handles, so iOS swipes
//    no rows; Deezer deletes only in its delete mode (the Edit button,
//    -displayDeleteButtons: a red minus per row, whose Delete action calls
//    -deleteRowInTableView:atIndexPath:). Deezit adds its own swipe: drag a
//    row to the right for a Delete button, keep dragging to delete it.
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
#import "DZIcons.h"

@interface DZRQueueListViewController : UIViewController
- (UITableView *)tableView;
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip;
- (BOOL)canDeleteRowAtIndexPath:(NSIndexPath *)ip;
- (void)deleteRowInTableView:(UITableView *)tv atIndexPath:(NSIndexPath *)ip;
- (BOOL)canEditQueueList;
- (BOOL)isDeleting;
- (NSUInteger)currentTrackIndex;
@end

@interface DZRPlayerTrackCell : UITableViewCell
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

// The destinations for the track playing now, as (title, Tempo icon, block).
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
            [out addObject:@[[NSString stringWithFormat:@"Go to “%@”", name], @"human", go]];
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
        [out addObject:@[[NSString stringWithFormat:@"Go to “%@”", name], @"disc", go]];
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
            [actions addObject:[UIAction actionWithTitle:d[0] image:DZIcon(d[1], [d[1] isEqualToString:@"human"] ? @"person.crop.circle" : @"square.stack", 0) identifier:nil
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

#pragma mark - swipe right to delete

// Up next keeps its table in editing mode (that's what shows the reorder
// handles), and iOS doesn't swipe the rows of a table in editing mode: a row
// with the delete style gets a red minus button in front of it instead
// (Deezer shows those only in its own delete mode, after its Edit button).
// So Deezit swipes the rows itself: drag a row to the right and a red Delete
// button shows behind it. Let go past the button and it stays open (tap it
// to delete, tap anywhere else or scroll to close); keep dragging past half
// the row and letting go deletes it. Deleting goes through Deezer's own
// -deleteRowInTableView:atIndexPath:, what its Delete action calls, so only
// rows Deezer can delete (canDeleteRowAtIndexPath:) can be swiped.

static const CGFloat kDZSwipeButton = 88;   // width of the open Delete button
static const CGFloat kDZSwipeFull = 0.5;    // share of the row past which letting go deletes
static void *kDZSwiperKey = &kDZSwiperKey;  // table -> its DZRowSwiper
static void *kDZHiddenKey = &kDZHiddenKey;  // cell -> @YES while hidden after a delete

static void restoreCell(UITableViewCell *cell) {
    if (!objc_getAssociatedObject(cell, kDZHiddenKey)) return;
    objc_setAssociatedObject(cell, kDZHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.alpha = 1;
    cell.transform = CGAffineTransformIdentity;
}

// a touch on a row's reorder handle drags the row, never swipes it
static BOOL onReorderControl(UITableView *tv, CGPoint p) {
    UIView *hit = [tv hitTest:p withEvent:nil];
    for (UIView *v = hit; v && v != tv; v = v.superview)
        if ([NSStringFromClass([v class]) rangeOfString:@"Reorder"].location != NSNotFound) return YES;
    return NO;
}

// Deezer's own title for its Delete action, in the app's language
static NSString *deleteTitle(DZRQueueListViewController *vc, UITableView *tv, NSIndexPath *ip) {
    UISwipeActionsConfiguration *c = [vc tableView:tv trailingSwipeActionsConfigurationForRowAtIndexPath:ip];
    NSString *t = c.actions.firstObject.title;
    return t.length ? t : @"Delete";
}

@interface DZRowSwiper : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) DZRQueueListViewController *owner;
@property (nonatomic, weak) UITableView *table;
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic, strong) UITapGestureRecognizer *tap;
@property (nonatomic, strong) UITableViewCell *cell;   // the row being swiped or left open
@property (nonatomic, strong) UIButton *button;        // the red Delete behind it
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) CGFloat offset, startOffset;
@property (nonatomic) BOOL armed, open;
- (void)closeAnimated:(BOOL)animated;
@end

static __weak DZRowSwiper *sSwiper;   // the Up next on screen

@implementation DZRowSwiper

- (instancetype)initWithOwner:(DZRQueueListViewController *)vc table:(UITableView *)tv {
    if ((self = [super init])) {
        _owner = vc;
        _table = tv;
        _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
        _pan.delegate = self;
        _pan.maximumNumberOfTouches = 1;
        [tv addGestureRecognizer:_pan];
        // a sideways drag is ours; anything else fails at once and scrolls
        [tv.panGestureRecognizer requireGestureRecognizerToFail:_pan];
        [tv.panGestureRecognizer addTarget:self action:@selector(tableScrolled:)];
        _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tappedElsewhere:)];
        _tap.delegate = self;
        _tap.enabled = NO;   // only while a row is open, so taps on rows still play them
        [tv addGestureRecognizer:_tap];
    }
    return self;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
    if (g == self.tap) return self.button && ![touch.view isDescendantOfView:self.button];
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    if (g == self.tap) return self.open;
    UITableView *tv = self.table;
    DZRQueueListViewController *vc = self.owner;
    if (!tv || !vc) return NO;
    CGPoint v = [self.pan velocityInView:tv];
    if (fabs(v.x) <= fabs(v.y)) return NO;
    CGPoint loc = [self.pan locationInView:tv], t = [self.pan translationInView:tv];
    CGPoint start = CGPointMake(loc.x - t.x, loc.y - t.y);
    NSIndexPath *ip = [tv indexPathForRowAtPoint:start];
    if (!ip) return NO;
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    BOOL openRow = self.open && cell && cell == self.cell;
    if (v.x < 0 && !openRow) return NO;   // to the right, or back on the open row
    if (onReorderControl(tv, start)) return NO;
    return [vc canDeleteRowAtIndexPath:ip];
}

// the row where it is now, ignoring the swipe's translation
- (CGRect)rowFrame {
    UITableViewCell *c = self.cell;
    CGSize s = c.bounds.size;
    return CGRectMake(c.center.x - s.width / 2, c.center.y - s.height / 2, s.width, s.height);
}

- (void)setOffsetValue:(CGFloat)dx {
    self.offset = dx;
    self.cell.transform = dx > 0 ? CGAffineTransformMakeTranslation(dx, 0) : CGAffineTransformIdentity;
    CGRect row = [self rowFrame];
    self.button.frame = CGRectMake(row.origin.x, row.origin.y, dx, row.size.height);
    // the label rides along the row's edge once the button is fully out
    self.label.frame = CGRectMake(MAX(0, dx - kDZSwipeButton), 0, kDZSwipeButton, row.size.height);
}

- (void)attachTo:(UITableViewCell *)cell at:(NSIndexPath *)ip {
    self.cell = cell;
    self.offset = 0;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.backgroundColor = UIColor.systemRedColor;
    b.clipsToBounds = YES;
    [b addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
    UILabel *l = [UILabel new];
    l.text = deleteTitle(self.owner, self.table, ip);
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    [b addSubview:l];
    [cell.superview insertSubview:b belowSubview:cell];
    self.button = b;
    self.label = l;
    [self setOffsetValue:0];
}

- (void)panned:(UIPanGestureRecognizer *)g {
    UITableView *tv = self.table;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint loc = [g locationInView:tv], t = [g translationInView:tv];
            NSIndexPath *ip = [tv indexPathForRowAtPoint:CGPointMake(loc.x - t.x, loc.y - t.y)];
            UITableViewCell *cell = ip ? [tv cellForRowAtIndexPath:ip] : nil;
            if (!cell) {
                g.enabled = NO;
                g.enabled = YES;
                return;
            }
            if (cell != self.cell) {
                [self closeAnimated:YES];
                [self attachTo:cell at:ip];
            }
            self.startOffset = self.offset;
            self.armed = NO;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!self.cell) return;
            CGFloat w = self.cell.bounds.size.width;
            CGFloat dx = MAX(0, MIN(w, self.startOffset + [g translationInView:tv].x));
            [self setOffsetValue:dx];
            BOOL armed = dx > w * kDZSwipeFull;
            if (armed != self.armed) {
                self.armed = armed;
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!self.cell) return;
            CGFloat w = self.cell.bounds.size.width, dx = self.offset, vx = [g velocityInView:tv].x;
            BOOL ended = g.state == UIGestureRecognizerStateEnded;
            if (ended && (dx > w * kDZSwipeFull || (vx > 1500 && dx > w * 0.3))) [self deleteRow];
            else if (ended && dx > kDZSwipeButton * 0.6 && vx > -200) [self openRow];
            else [self closeAnimated:YES];
            break;
        }
        default:
            break;
    }
}

- (void)openRow {
    self.open = YES;
    self.tap.enabled = YES;
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ [self setOffsetValue:kDZSwipeButton]; } completion:nil];
}

- (void)closeAnimated:(BOOL)animated {
    UITableViewCell *cell = self.cell;
    UIButton *b = self.button;
    self.cell = nil;
    self.button = nil;
    self.label = nil;
    self.open = NO;
    self.armed = NO;
    self.offset = 0;
    self.tap.enabled = NO;
    if (!cell && !b) return;
    void (^back)(void) = ^{
        cell.transform = CGAffineTransformIdentity;
        b.frame = CGRectMake(b.frame.origin.x, b.frame.origin.y, 0, b.frame.size.height);
    };
    if (!animated) {
        back();
        [b removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:back
                     completion:^(BOOL finished) { [b removeFromSuperview]; }];
}

- (void)deleteRow {
    UITableView *tv = self.table;
    DZRQueueListViewController *vc = self.owner;
    UITableViewCell *cell = self.cell;
    UIButton *b = self.button;
    UILabel *l = self.label;
    self.cell = nil;
    self.button = nil;
    self.label = nil;
    self.open = NO;
    self.armed = NO;
    self.offset = 0;
    self.tap.enabled = NO;
    if (!cell) return;
    CGFloat w = cell.bounds.size.width;
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState animations:^{
        cell.transform = CGAffineTransformMakeTranslation(w, 0);
        b.frame = CGRectMake(b.frame.origin.x, b.frame.origin.y, w, b.frame.size.height);
        l.frame = CGRectMake(w - kDZSwipeButton, 0, kDZSwipeButton, b.frame.size.height);
    } completion:^(BOOL finished) {
        NSIndexPath *ip = tv ? [tv indexPathForCell:cell] : nil;
        // hidden while Deezer takes the row out, then back for reuse
        objc_setAssociatedObject(cell, kDZHiddenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.alpha = 0;
        cell.transform = CGAffineTransformIdentity;
        [UIView animateWithDuration:0.25 animations:^{ b.alpha = 0; } completion:^(BOOL f) { [b removeFromSuperview]; }];
        if (ip && vc && [vc canDeleteRowAtIndexPath:ip]) {
            DZLog("up next: row %ld deleted by a swipe", (long)ip.row);
            [vc deleteRowInTableView:tv atIndexPath:ip];
        } else {
            DZLog("up next: swiped row is gone or can't be deleted any more, nothing deleted");
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            restoreCell(cell);
        });
    }];
}

- (void)deleteTapped {
    if (self.cell) [self deleteRow];
}

- (void)tappedElsewhere:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded) [self closeAnimated:YES];
}

- (void)tableScrolled:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.cell) [self closeAnimated:YES];
}

@end

static void installSwiper(DZRQueueListViewController *vc) {
    UITableView *tv = [vc respondsToSelector:@selector(tableView)] ? [vc tableView] : nil;
    if (![tv isKindOfClass:[UITableView class]]) return;
    DZRowSwiper *s = objc_getAssociatedObject(tv, kDZSwiperKey);
    if (!s) {
        s = [[DZRowSwiper alloc] initWithOwner:vc table:tv];
        objc_setAssociatedObject(tv, kDZSwiperKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DZLog("up next: swipe a row to the right to delete it (table in editing mode: %@)", yesNo(tv.isEditing));
    }
    sSwiper = s;
}

#pragma mark - hooks

%group DZQueueSwipeHooks

%hook DZRQueueListViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    holdContentPop(self, YES);
}

%end

%end

// a swiped row's cell, when Deezer reuses it, goes back to normal
%group DZQueueCellHooks

%hook DZRPlayerTrackCell

- (void)prepareForReuse {
    %orig;
    if (sSwiper.cell == (UITableViewCell *)self) [sSwiper closeAnimated:NO];
    restoreCell((UITableViewCell *)self);
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
        installSwiper((DZRQueueListViewController *)self);
        logQueueState((DZRQueueListViewController *)self);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    if (sQueueClass && [self isKindOfClass:sQueueClass]) {
        holdContentPop(self, NO);
        UITableView *tv = [(DZRQueueListViewController *)self tableView];
        DZRowSwiper *s = [tv isKindOfClass:[UITableView class]] ? objc_getAssociatedObject(tv, kDZSwiperKey) : nil;
        [s closeAnimated:NO];
    }
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
            implements(queue, @selector(canDeleteRowAtIndexPath:)) && implements(queue, @selector(deleteRowInTableView:atIndexPath:)) &&
            implements(queue, @selector(tableView))) {
            sQueueClass = queue;
            %init(DZQueueSwipeHooks);
            %init(DZQueueLeaveHooks);
            if (implements(objc_getClass("DZRPlayerTrackCell"), @selector(prepareForReuse))) %init(DZQueueCellHooks);
            DZLog("player: up next rows delete on a swipe to the right");
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
