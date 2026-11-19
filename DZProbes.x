// Runtime probes: answer what static analysis couldn't (docs/ANALYSIS.md,
// "Open questions for runtime") by logging to the debug panel.
//
// - Which view controller is the full-screen player root
//   (DZRPlayerViewController vs DZRPlayerMainViewController), and which one
//   hosts Settings: every player / settings / queue / lyrics screen that
//   appears is logged with its parent and presenter chain.
//
// One hook on -[UIViewController viewDidAppear:] (UIKit implements it on
// UIViewController itself, so subclasses that call super reach it). It does a
// cheap class-name check and returns for everything else.

#import <UIKit/UIKit.h>
#import "DZLog.h"

static NSRegularExpression *sWatch;

static NSString *vcName(UIViewController *vc) {
    return vc ? NSStringFromClass([vc class]) : @"-";
}

static void probeAppeared(UIViewController *vc) {
    NSString *name = vcName(vc);
    if ([name hasPrefix:@"DZSettings"] || [name hasPrefix:@"DZDebug"]) return; // Deezit's own pages
    if (![sWatch firstMatchInString:name options:0 range:NSMakeRange(0, name.length)]) return;

    NSMutableArray *parents = [NSMutableArray array];
    for (UIViewController *p = vc.parentViewController; p && parents.count < 4; p = p.parentViewController) {
        [parents addObject:vcName(p)];
    }
    CGRect f = [vc.view convertRect:vc.view.bounds toView:nil];
    DZLog("ui: appeared %@ · parents [%@] · presented by %@ · frame %.0fx%.0f",
          name, [parents componentsJoinedByString:@" > "], vcName(vc.presentingViewController),
          f.size.width, f.size.height);
}

%group DZProbeHooks

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    probeAppeared(self);
}
%end

%end

void DZProbesInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sWatch = [NSRegularExpression regularExpressionWithPattern:@"Player|Settings|Queue|Lyrics|NowPlaying|Cover"
                                                           options:NSRegularExpressionCaseInsensitive
                                                             error:nil];
        %init(DZProbeHooks);
        DZLog("probes: logging player / settings / queue screens as they appear");
    });
}
