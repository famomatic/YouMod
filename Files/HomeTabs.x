#import "Headers.h"
#import <objc/runtime.h>

// Home top tabs (YouTube 21.44+): the Home/Subs/Music/Live/More strip is the server's tab structure
// (-[YTISingleColumnBrowseResultsRenderer tabsArray]) shown by YTTabsViewController (underline style) or, when
// the browse controller's _enableHomeTabsFork is set, by YTHomeTabsViewController (pill style).

static id YMKV(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static NSInteger YMHomeTabsStyle(void) {
    static NSInteger style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ style = INTFORVAL(HomeTabsStyle); });
    return style;
}

// Remove the tabs the user switched off. Only touches the Home feed (the tab set that contains FEwhat_to_watch);
// channel pages, Library etc. use the same controller and are left alone.
static void YMFilterHomeTabs(id model) {
    BOOL hideSubs = IS_ENABLED(HomeTabHideSubs), hideMusic = IS_ENABLED(HomeTabHideMusic);
    BOOL hideLive = IS_ENABLED(HomeTabHideLive), hideMore = IS_ENABLED(HomeTabHideMore);
    BOOL hideOthers = IS_ENABLED(HomeTabHideOthers);
    if (!(hideSubs || hideMusic || hideLive || hideMore || hideOthers)) return;

    NSMutableArray *tabs = YMKV(model, @"tabsArray");
    if (![tabs isKindOfClass:[NSMutableArray class]] || tabs.count < 2) return;

    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:tabs.count];
    BOOL isHome = NO;
    for (id tab in tabs) {
        NSString *tid = YMKV(YMKV(tab, @"tabRenderer"), @"tabIdentifier");
        if (![tid isKindOfClass:[NSString class]]) tid = @"";
        [ids addObject:tid];
        if ([tid isEqualToString:@"FEwhat_to_watch"]) isHome = YES;
    }
    if (!isHome) return;

    NSMutableIndexSet *remove = [NSMutableIndexSet indexSet];
    [ids enumerateObjectsUsingBlock:^(NSString *tid, NSUInteger idx, BOOL *stop) {
        if (!tid.length || [tid isEqualToString:@"FEwhat_to_watch"]) return;
        BOOL hide;
        if ([tid containsString:@"SUBSCRIPTIONS"]) hide = hideSubs || hideOthers;
        else if ([tid containsString:@"MUSIC"]) hide = hideMusic || hideOthers;
        else if ([tid containsString:@"LIVE"]) hide = hideLive || hideOthers;
        else if ([tid containsString:@"MORE"]) hide = hideMore || hideOthers;
        else hide = hideOthers;
        if (hide) [remove addIndex:idx];
    }];
    if (remove.count == 0 || remove.count >= tabs.count) return;
    [tabs removeObjectsAtIndexes:remove];
}

%hook YTTabsViewController
- (void)loadWithModel:(id)model { YMFilterHomeTabs(model); %orig; }
- (void)updateWithModel:(id)model isDefaultModel:(BOOL)isDefault reloadContentViewControllers:(BOOL)reload {
    YMFilterHomeTabs(model);
    %orig;
}
%end

%hook YTHomeTabsViewController
- (void)loadWithModel:(id)model { YMFilterHomeTabs(model); %orig; }
- (void)updateWithModel:(id)model isDefaultModel:(BOOL)isDefault reloadContentViewControllers:(BOOL)reload {
    YMFilterHomeTabs(model);
    %orig;
}
%end

// Style: pick the tab implementation. 1 = underline (YTTabsViewController), 2 = pill (YTHomeTabsViewController).
static void YMForceHomeTabsFork(id vc) {
    NSInteger style = YMHomeTabsStyle();
    if (style != 1 && style != 2) return;
    Ivar ivar = class_getInstanceVariable(object_getClass(vc), "_enableHomeTabsFork");
    if (!ivar) return;
    *(BOOL *)((uint8_t *)(__bridge void *)vc + ivar_getOffset(ivar)) = (style == 2);
}

%hook YTBrowseResponseViewController
- (id)initWithService:(id)service parentResponder:(id)responder topViewControllerProvider:(id)provider {
    id me = %orig;
    if (me) YMForceHomeTabsFork(me);
    return me;
}
- (id)initWithService:(id)service parentResponder:(id)responder {
    id me = %orig;
    if (me) YMForceHomeTabsFork(me);
    return me;
}
- (void)viewDidLoad { YMForceHomeTabsFork(self); %orig; }
- (void)loadWithModel:(id)model { YMForceHomeTabsFork(self); %orig; }
- (void)loadContentWithModel:(id)model { YMForceHomeTabsFork(self); %orig; }
- (id)contentViewControllerForModel:(id)model { YMForceHomeTabsFork(self); return %orig; }
%end

// The pill tabs gate their look on these (off by default on the server side)
%hook YTColdConfig
- (BOOL)designSystemFoundationsIosHomeTabBarLightMode { return YMHomeTabsStyle() == 2 ? YES : %orig; }
- (BOOL)designSystemFoundationsIosMotionOnHomeTabBar { return YMHomeTabsStyle() == 2 ? YES : %orig; }
%end
