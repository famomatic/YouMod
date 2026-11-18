#import "Headers.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Watch page panel tabs (comments panel under the player, swipe left/right): on 21.46 the server sends the
// comments panel as a tabbed panel (Comments + Members) and the Members tab can come up as the default.
// Options: hide the Members tab, and pick the tab that is shown first.
// The panel's tabs are -[YTITabbedEngagementPanelContentRenderer tabsArray]; the tab kind is recognised from the
// tab's identifier/title text, so what was seen is kept for the UI dump (YMPanelTabsLog) in case a tab needs a new match.

static id YMPKV(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSMutableArray *gYMPanelTabLog;
NSString *YMPanelTabsLog(void) {
    @synchronized ([NSNull null]) {
        return gYMPanelTabLog.count ? [gYMPanelTabLog componentsJoinedByString:@"\n"] : @"(no tabbed panel opened since launch)";
    }
}

// Identifier and title text of a tab, found through the layers the renderer may be wrapped in.
static NSString *YMPanelTabProbe(id tab) {
    NSMutableString *probe = [NSMutableString string];
    NSArray *layers = @[tab ?: [NSNull null], YMPKV(tab, @"engagementPanelTabRenderer") ?: [NSNull null], YMPKV(tab, @"tabRenderer") ?: [NSNull null]];
    for (id layer in layers) {
        if (layer == [NSNull null]) continue;
        for (NSString *key in @[@"tabIdentifier", @"identifier", @"targetId", @"panelIdentifier", @"title"]) {
            id v = YMPKV(layer, key);
            if (!v) continue;
            NSString *s = [v isKindOfClass:[NSString class]] ? v : [v description];
            if (s.length > 200) s = [s substringToIndex:200];
            [probe appendFormat:@" %@", s];
        }
    }
    return probe.length ? probe : [tab description];
}

// 1 = comments, 2 = members, 0 = anything else
static NSInteger YMPanelTabKind(NSString *probe) {
    NSString *p = probe.lowercaseString;
    if ([p containsString:@"member"] || [p containsString:@"sponsor"] || [p containsString:@"멤버"] || [p containsString:@"회원"] || [p containsString:@"가입"]) return 2;
    if ([p containsString:@"comment"] || [p containsString:@"댓글"]) return 1;
    return 0;
}

// Finds the tabs array on the model or on a renderer inside it.
static NSMutableArray *YMPanelTabsOf(id model) {
    for (NSString *path in @[@"", @"tabbedEngagementPanelContentRenderer", @"content.tabbedEngagementPanelContentRenderer", @"renderer"]) {
        id obj = path.length ? YMPKV(model, path) : model;
        id tabs = YMPKV(obj, @"tabsArray");
        if ([tabs isKindOfClass:[NSMutableArray class]]) return tabs;
    }
    return nil;
}

// Returns the index the default tab ended up at (-1 = leave YouTube's choice)
static NSInteger YMFilterPanelTabs(id model) {
    NSMutableArray *tabs = YMPanelTabsOf(model);
    if (!tabs || tabs.count < 2) return -1;

    NSMutableArray<NSNumber *> *kinds = [NSMutableArray array];
    NSMutableArray<NSString *> *probes = [NSMutableArray array];
    for (id tab in tabs) {
        NSString *probe = YMPanelTabProbe(tab);
        [probes addObject:probe];
        [kinds addObject:@(YMPanelTabKind(probe))];
    }
    @synchronized ([NSNull null]) {
        if (!gYMPanelTabLog) gYMPanelTabLog = [NSMutableArray array];
        for (NSUInteger i = 0; i < tabs.count; i++) {
            NSString *line = [NSString stringWithFormat:@"tab %lu kind=%@ class=%@ :%@", (unsigned long)i, kinds[i], NSStringFromClass([tabs[i] class]), [probes[i] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
            [gYMPanelTabLog addObject:line];
        }
        while (gYMPanelTabLog.count > 40) [gYMPanelTabLog removeObjectAtIndex:0];
    }

    if (IS_ENABLED(PanelHideMembersTab)) {
        NSMutableIndexSet *remove = [NSMutableIndexSet indexSet];
        [kinds enumerateObjectsUsingBlock:^(NSNumber *k, NSUInteger idx, BOOL *stop) { if (k.integerValue == 2) [remove addIndex:idx]; }];
        if (remove.count && remove.count < tabs.count) {
            [tabs removeObjectsAtIndexes:remove];
            [kinds removeObjectsAtIndexes:remove];
        }
    }

    NSInteger want = INTFORVAL(PanelDefaultTab); // 0 = YouTube, 1 = comments, 2 = members
    if (want == 1 || want == 2) {
        NSUInteger idx = [kinds indexOfObject:@(want)];
        if (idx != NSNotFound) return (NSInteger)idx;
    }
    return -1;
}

%hook YTTabbedEngagementPanelContentViewController
- (void)loadWithModel:(id)model {
    NSInteger index = YMFilterPanelTabs(model);
    %orig;
    if (index >= 0) {
        // YouTube has laid the pages out by now; moving to the tab is the same call a tap on its title makes
        dispatch_async(dispatch_get_main_queue(), ^{
            id me = (id)self; // forward-declared class: no direct messaging
            if ([me respondsToSelector:@selector(switchToTabAtIndex:)]) ((void (*)(id, SEL, NSUInteger))objc_msgSend)(me, @selector(switchToTabAtIndex:), (NSUInteger)index);
        });
    }
}
%end

%ctor {
    YMRegisterDefaults();
    %init;
}
