#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DZSettingsEntry.h"
#import "DZSettingsViewController.h"
#import "DZLog.h"

@interface DZSettingsGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DZSettingsGestureTarget
- (void)fire:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) DZPresentSettings();
}
// never steal touches from Deezer's own gestures
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
@end

static DZSettingsGestureTarget *sTarget;
static void *kDZGestureAttachedKey = &kDZGestureAttachedKey;

static void attachToWindow(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, kDZGestureAttachedKey)) return;
    UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:sTarget action:@selector(fire:)];
    g.numberOfTouchesRequired = 3;
    g.minimumPressDuration = 0.6;
    g.cancelsTouchesInView = NO;
    g.delegate = sTarget;
    [w addGestureRecognizer:g];
    objc_setAssociatedObject(w, kDZGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIWindow *keyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static UIViewController *topViewController(UIViewController *vc) {
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

void DZPresentSettings(void) {
    UIViewController *top = topViewController(keyWindow().rootViewController);
    if (!top) return;
    // already showing
    if ([top isKindOfClass:[UINavigationController class]] &&
        [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:[DZSettingsViewController class]]) {
        return;
    }
    [top presentViewController:[DZSettingsViewController presentableController] animated:YES completion:nil];
}

void DZSettingsEntryInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTarget = [DZSettingsGestureTarget new];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            attachToWindow(n.object);
        }];
        DZLog("settings: three-finger long press opens Deezit");
    });
}
