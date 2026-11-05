#import "Headers.h"
#import <objc/runtime.h>
#import <sys/utsname.h>

// UI dump: writes the whole live view hierarchy (class, frame, accessibilityIdentifier/Label, ASDK node class)
// plus a summary of every accessibility identifier to a text file and offers it through the share sheet.
// Used to find the identifiers/classes the filters hook into after YouTube changes its UI.

static const NSUInteger kYMDumpMaxLines = 60000;

static NSString *YMTrim(NSString *s, NSUInteger max) {
    if (s.length <= max) return s;
    return [[s substringToIndex:max] stringByAppendingString:@"…"];
}

static NSString *YMOneLine(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
}

static id YMSafeValue(id obj, NSString *key) {
    @try {
        SEL sel = NSSelectorFromString(key);
        if (![obj respondsToSelector:sel]) return nil;
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void YMDumpView(UIView *v, int depth, NSMutableString *out, NSMutableDictionary<NSString *, NSMutableDictionary *> *ids, NSUInteger *lines) {
    if (*lines >= kYMDumpMaxLines) return;
    (*lines)++;

    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;
    NSMutableString *line = [NSMutableString stringWithFormat:@"%*s%@ (%.0f,%.0f %.0fx%.0f)", depth * 2, "", cls, f.origin.x, f.origin.y, f.size.width, f.size.height];
    if (v.hidden) [line appendString:@" hidden"];
    if (v.alpha < 0.01) [line appendString:@" alpha0"];

    NSString *iden = v.accessibilityIdentifier;
    NSString *label = v.accessibilityLabel;
    if (iden.length) [line appendFormat:@" id=\"%@\"", YMOneLine(iden)];
    if (label.length) [line appendFormat:@" label=\"%@\"", YMOneLine(YMTrim(label, 80))];

    id node = YMSafeValue(v, @"keepalive_node");
    if (node) [line appendFormat:@" node=%@", NSStringFromClass([node class])];

    UIResponder *next = v.nextResponder;
    if ([next isKindOfClass:[UIViewController class]]) [line appendFormat:@" vc=%@", NSStringFromClass([next class])];

    [out appendFormat:@"%@\n", line];

    if (iden.length) {
        NSMutableDictionary *entry = ids[iden];
        if (!entry) {
            entry = [@{ @"count": @0, @"classes": [NSMutableSet set], @"label": label ?: @"", @"parents": [NSMutableSet set] } mutableCopy];
            ids[iden] = entry;
        }
        entry[@"count"] = @([entry[@"count"] integerValue] + 1);
        [entry[@"classes"] addObject:cls];
        if (v.superview) [entry[@"parents"] addObject:NSStringFromClass([v.superview class])];
        if (!((NSString *)entry[@"label"]).length && label.length) entry[@"label"] = label;
    }

    for (UIView *sub in v.subviews) YMDumpView(sub, depth + 1, out, ids, lines);
}

static NSString *YMBuildDump(void) {
    NSMutableString *out = [NSMutableString string];
    NSBundle *main = [NSBundle mainBundle];
    struct utsname si;
    uname(&si);

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    [out appendString:@"=== YouMod UI dump ===\n"];
    [out appendFormat:@"date: %@\n", [df stringFromDate:[NSDate date]]];
    [out appendFormat:@"app: %@ (%@) %@\n", main.infoDictionary[@"CFBundleDisplayName"] ?: main.infoDictionary[@"CFBundleName"], main.bundleIdentifier, main.infoDictionary[@"CFBundleShortVersionString"]];
    [out appendFormat:@"device: %s, iOS %@\n", si.machine, UIDevice.currentDevice.systemVersion];
    [out appendFormat:@"tab bar style setting: %ld, float labels: %d\n", (long)INTFORVAL(TabBarStyle), IS_ENABLED(FloatBarLabels)];

    // Class presence for the classes the tweak depends on
    NSArray *classes = @[@"YTFloatingPivotBarView", @"YTPivotBarView", @"YTFloatingBarExperiment", @"YTHomeTabsView", @"YTHeaderContentComboView",
                         @"YTReelAccessoryView", @"YTReelTopBarView", @"YTReelPausedStateCarouselView", @"YTReelPlayerPivotButton",
                         @"YTReelWatchPlaybackOverlayView", @"YTReelContentView", @"YTMainAppControlsOverlayView",
                         @"YTInlinePlayerBarContainerView", @"YTWatchFloatingMiniplayerControlsBarView", @"YTWatchFloatingMiniplayerProgressBarView",
                         @"YTAdsInnerTubeContextDecorator", @"YTAdsInnerTubeContextDecoratorImpl"];
    [out appendString:@"\n=== CLASS PRESENCE ===\n"];
    for (NSString *c in classes) {
        Class k = NSClassFromString(c);
        [out appendFormat:@"%-48s %@\n", c.UTF8String, k ? [NSString stringWithFormat:@"yes (super %@)", NSStringFromClass(class_getSuperclass(k))] : @"NO"];
    }

    NSMutableString *tree = [NSMutableString string];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *ids = [NSMutableDictionary dictionary];
    NSUInteger lines = 0;

    NSMutableString *vcs = [NSMutableString string];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        [tree appendFormat:@"\n--- window %@ level=%.0f key=%d hidden=%d frame=%@ ---\n", NSStringFromClass([w class]), w.windowLevel, w.isKeyWindow, w.hidden, NSStringFromCGRect(w.frame)];
        YMDumpView(w, 0, tree, ids, &lines);

        UIViewController *vc = w.rootViewController;
        int d = 0;
        while (vc) {
            [vcs appendFormat:@"%*s%@\n", d * 2, "", NSStringFromClass([vc class])];
            for (UIViewController *child in vc.childViewControllers) {
                [vcs appendFormat:@"%*s- child %@\n", d * 2 + 2, "", NSStringFromClass([child class])];
            }
            vc = vc.presentedViewController;
            d++;
        }
    }

    [out appendString:@"\n=== VIEW CONTROLLERS ===\n"];
    [out appendString:vcs];

    [out appendFormat:@"\n=== ACCESSIBILITY IDENTIFIERS (%lu unique) ===\n", (unsigned long)ids.count];
    for (NSString *iden in [ids.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *e = ids[iden];
        NSString *classes = [[[e[@"classes"] allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
        NSString *parents = [[[e[@"parents"] allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
        NSString *label = e[@"label"];
        [out appendFormat:@"%@  x%@  [%@]  parent=[%@]%@\n", iden, e[@"count"], classes, parents, label.length ? [NSString stringWithFormat:@"  label=\"%@\"", YMOneLine(YMTrim(label, 60))] : @""];
    }

    [out appendString:@"\n=== VIEW TREE ===\n"];
    [out appendString:tree];
    if (lines >= kYMDumpMaxLines) [out appendString:@"\n(truncated)\n"];
    return out;
}

static void YMPresentDump(UIViewController *fallbackPresenter) {
    NSString *text = YMBuildDump();
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"YouMod-UIDump-%@.txt", [df stringFromDate:[NSDate date]]]];
    NSError *err = nil;
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];

    UIViewController *top = YouModTopViewController(nil) ?: fallbackPresenter;
    if (!top) return;
    if (err) {
        YTAlertView *alert = [%c(YTAlertView) infoDialog];
        alert.title = @"UI dump";
        alert.subtitle = err.localizedDescription;
        alert.shouldDismissOnBackgroundTap = YES;
        [alert show];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    if (share.popoverPresentationController) {
        share.popoverPresentationController.sourceView = top.view;
        share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 0, 0);
        share.popoverPresentationController.permittedArrowDirections = 0;
    }
    [top presentViewController:share animated:YES completion:nil];
}

void YouModDumpUIHierarchy(UIViewController *presenter, NSTimeInterval delay) {
    if (delay <= 0) {
        YMPresentDump(presenter);
        return;
    }
    YTAlertView *alert = [%c(YTAlertView) infoDialog];
    alert.title = LOC(@"UI_DUMP");
    alert.subtitle = [NSString stringWithFormat:LOC(@"UI_DUMP_DELAYED_NOTICE"), (int)delay];
    alert.shouldDismissOnBackgroundTap = YES;
    [alert show];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YMPresentDump(presenter);
    });
}
