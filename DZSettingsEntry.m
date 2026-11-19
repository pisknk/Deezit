#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DZSettingsEntry.h"
#import "DZSettingsViewController.h"
#import "DZDebugViewController.h"
#import "DZLog.h"

#ifndef DEEZIT_VERSION
#define DEEZIT_VERSION "dev"
#endif

@interface DZGestureTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DZGestureTarget
- (void)settingsPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) DZPresentSettings();
}
- (void)debugTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateRecognized) DZPresentDebug();
}
// never steal touches from Deezer's own gestures
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
@end

static DZGestureTarget *sTarget;
static void *kDZGestureAttachedKey = &kDZGestureAttachedKey;

static void attachToWindow(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w, kDZGestureAttachedKey)) return;

    // three-finger hold: settings (temporary until the in-Deezer entry points land)
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:sTarget action:@selector(settingsPress:)];
    hold.numberOfTouchesRequired = 3;
    hold.minimumPressDuration = 0.6;
    hold.cancelsTouchesInView = NO;
    hold.delegate = sTarget;
    [w addGestureRecognizer:hold];

    // three-finger double tap: debug panel (same gesture as CCBoost)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:sTarget action:@selector(debugTap:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = sTarget;
    [w addGestureRecognizer:tap];

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

static BOOL isShowing(UIViewController *top, Class cls) {
    return [top isKindOfClass:[UINavigationController class]] &&
           [((UINavigationController *)top).viewControllers.firstObject isKindOfClass:cls];
}

void DZPresentSettings(void) {
    UIViewController *top = topViewController(keyWindow().rootViewController);
    if (!top || isShowing(top, [DZSettingsViewController class])) return;
    [top presentViewController:[DZSettingsViewController presentableController] animated:YES completion:nil];
}

void DZPresentDebug(void) {
    UIViewController *top = topViewController(keyWindow().rootViewController);
    if (!top || isShowing(top, [DZDebugViewController class])) return;
    [top presentViewController:[DZDebugViewController presentableController] animated:YES completion:nil];
}

void DZSettingsEntryInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sTarget = [DZGestureTarget new];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(NSNotification *n) {
            attachToWindow(n.object);
        }];

        // once per Deezit version: confirm the injection worked and say how to get in
        __block id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            observer = nil;
            attachToWindow(keyWindow());
            NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
            NSString *key = @"Deezit.introShownFor";
            if (![[d stringForKey:key] isEqualToString:@DEEZIT_VERSION]) {
                [d setObject:@DEEZIT_VERSION forKey:key];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DZToast(@"Deezit " DEEZIT_VERSION " loaded\n3-finger hold: settings · 3-finger double tap: debug");
                });
            }
        }];
        DZLog("entry: three-finger hold = settings, three-finger double tap = debug panel");
    });
}
