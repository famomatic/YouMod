#import "Headers.h"
#import <objc/runtime.h>
#import "DownloadQueue.h"

// The Downloads tab is YouMod's own screen, not a YouTube browse page: its pivot
// item uses this identifier and its content is YMDownloadsTabViewController.
static NSString *const YMDownloadsPivotIdentifier = @"FEyoumod_downloads";
static const int YMDownloadsIconType = 18;

// Remove the tab width cap. -[YTPivotBarView updateTabWidths] gives each tab
// (bar width / tab count), then clamps it to 105pt whenever the layout style's
// restrictPivotBarTabWidths is YES - which YTDefaultLayoutStyle hard-codes. With
// fewer tabs (or a wider screen) that clamp is what left the tabs bunched in the
// middle with empty space on both sides. Confirmed against 21.40.5's binary.
%hook YTDefaultLayoutStyle
- (BOOL)restrictPivotBarTabWidths { return NO; }
%end

// Tab icons
%hook YTAppPivotBarItemStyle
- (UIImage *)pivotBarItemIconImageWithIconType:(int)type color:(UIColor *)color useNewIcons:(BOOL)isNew selected:(BOOL)isSelected {
    if (type == YMDownloadsIconType) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        UIImage *symbol = [UIImage systemImageNamed:isSelected ? @"arrow.down.circle.fill" : @"arrow.down.circle" withConfiguration:config];
        return [symbol imageWithTintColor:color ?: UIColor.labelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    if (type == 1 || type == 2 || type == 3 || type == 4 || type == 5 || type == 6 || type == 7 || type == 8 || type == 9 || type == 10 || type == 11 || type == 12 || type == 13 || type == 14 || type == 15 || type == 16 || type == 17) {
        NSString *imageName;
        if (type == 1) imageName = isSelected ? @"icons/history_selected" : @"icons/history";
        else if (type == 2) imageName = isSelected ? @"icons/gaming_selected" : @"icons/gaming";
        else if (type == 3) imageName = isSelected ? @"icons/sports_selected" : @"icons/sports";
        else if (type == 4) imageName = isSelected ? @"icons/noti_selected" : @"icons/noti";
        else if (type == 5) imageName = isSelected ? @"icons/news_selected" : @"icons/news";
        else if (type == 6) imageName = isSelected ? @"icons/music_selected" : @"icons/music";
        else if (type == 7) imageName = isSelected ? @"icons/watchlater_selected" : @"icons/watchlater";
        else if (type == 8) imageName = isSelected ? @"icons/playlist_selected" : @"icons/playlist";
        else if (type == 9) imageName = isSelected ? @"icons/like_selected" : @"icons/like";
        else if (type == 10) imageName = isSelected ? @"icons/live_selected" : @"icons/live";
        else if (type == 11) imageName = isSelected ? @"icons/post_selected" : @"icons/post";
        else if (type == 12) imageName = isSelected ? @"icons/video_selected" : @"icons/video";
        else if (type == 13) imageName = isSelected ? @"icons/movie_selected" : @"icons/movie";
        else if (type == 14) imageName = isSelected ? @"icons/course_selected" : @"icons/course";
        else if (type == 15) imageName = isSelected ? @"icons/minigame_selected" : @"icons/minigame";
        else if (type == 16) imageName = isSelected ? @"icons/fashion_selected" : @"icons/fashion";
        else if (type == 17) imageName = isSelected ? @"icons/learning_selected" : @"icons/learning";
        YTAssetLoader *al = [[%c(YTAssetLoader) alloc] initWithBundle:YouModBundle()];
        return [al imageNamed:imageName];
    }
    return %orig;
}
%end

static NSString *ymPivotIDForTabID(NSString *tabID) {
    if ([tabID isEqualToString:@"home"]) return @"FEwhat_to_watch";
    if ([tabID isEqualToString:@"shorts"]) return @"FEshorts";
    if ([tabID isEqualToString:@"create"]) return @"FEuploads";
    if ([tabID isEqualToString:@"subscriptions"]) return @"FEsubscriptions";
    if ([tabID isEqualToString:@"library"]) return @"FElibrary";
    if ([tabID isEqualToString:@"history"]) return [%c(YTIBrowseRequest) browseIDForHistory];
    if ([tabID isEqualToString:@"gaming"]) return [%c(YTIBrowseRequest) browseIDForGamingDestination];
    if ([tabID isEqualToString:@"sports"]) return [%c(YTIBrowseRequest) browseIDForSportsDestination];
    if ([tabID isEqualToString:@"notifications"]) return [%c(YTIBrowseRequest) browseIDForNotificationsInbox];
    if ([tabID isEqualToString:@"news"]) return @"UCYfdidRxbB8Qhf0Nx7ioOYw"; // FEnews_destination
    if ([tabID isEqualToString:@"music"]) return @"UC-9-kyTW8ZkZNDHQJ6FgpwQ";
    if ([tabID isEqualToString:@"watchlater"]) return @"VLWL";
    if ([tabID isEqualToString:@"playlist"]) return @"FEplaylist_aggregation";
    if ([tabID isEqualToString:@"like"]) return @"VLLL";
    if ([tabID isEqualToString:@"live"]) return @"UC4R8DWoMoI7CAwX8_LjQHig";
    if ([tabID isEqualToString:@"post"]) return @"FEpost_home";
    if ([tabID isEqualToString:@"video"]) return @"UC3qapbGAd2-S75NkBY3XWww";
    if ([tabID isEqualToString:@"movie"]) return @"FEstorefront";
    if ([tabID isEqualToString:@"course"]) return @"FEcourses";
    if ([tabID isEqualToString:@"minigame"]) return @"FEmini_app_destination";
    if ([tabID isEqualToString:@"fashion"]) return @"UCrpQ4p1Ql_hG8rKXIKM1MOQ";
    if ([tabID isEqualToString:@"learning"]) return @"UCtFRv9O2AHqOZjjynzrv-xg";
    if ([tabID isEqualToString:@"downloads"]) return YMDownloadsPivotIdentifier;
    return nil;
}

static NSInteger ymIconTypeForTabID(NSString *tabID) {
    if ([tabID isEqualToString:@"history"]) return 1;
    if ([tabID isEqualToString:@"gaming"]) return 2;
    if ([tabID isEqualToString:@"sports"]) return 3;
    if ([tabID isEqualToString:@"notifications"]) return 4;
    if ([tabID isEqualToString:@"news"]) return 5;
    if ([tabID isEqualToString:@"music"]) return 6;
    if ([tabID isEqualToString:@"watchlater"]) return 7;
    if ([tabID isEqualToString:@"playlist"]) return 8;
    if ([tabID isEqualToString:@"like"]) return 9;
    if ([tabID isEqualToString:@"live"]) return 10;
    if ([tabID isEqualToString:@"post"]) return 11;
    if ([tabID isEqualToString:@"video"]) return 12;
    if ([tabID isEqualToString:@"movie"]) return 13;
    if ([tabID isEqualToString:@"course"]) return 14;
    if ([tabID isEqualToString:@"minigame"]) return 15;
    if ([tabID isEqualToString:@"fashion"]) return 16;
    if ([tabID isEqualToString:@"learning"]) return 17;
    if ([tabID isEqualToString:@"downloads"]) return YMDownloadsIconType;
    // YouTube's own icon types, for core tabs the server no longer sends (21.44 moved Subscriptions into the Home tabs)
    if ([tabID isEqualToString:@"home"]) return 65;
    if ([tabID isEqualToString:@"shorts"]) return 769;
    if ([tabID isEqualToString:@"subscriptions"]) return 66;
    if ([tabID isEqualToString:@"library"]) return 61;
    return 0;
}

static NSString *ymTitleForTabID(NSString *tabID) {
    if ([tabID isEqualToString:@"history"]) return LOC(@"HISTORY_TAB");
    if ([tabID isEqualToString:@"gaming"]) return LOC(@"GAMING_TAB");
    if ([tabID isEqualToString:@"sports"]) return LOC(@"SPORTS_TAB");
    if ([tabID isEqualToString:@"notifications"]) return LOC(@"NOTI_TAB");
    if ([tabID isEqualToString:@"news"]) return LOC(@"NEWS_TAB");
    if ([tabID isEqualToString:@"music"]) return LOC(@"MUSIC_TAB");
    if ([tabID isEqualToString:@"watchlater"]) return LOC(@"WATCH_LATER_TAB");
    if ([tabID isEqualToString:@"playlist"]) return LOC(@"PLAYLIST_TAB");
    if ([tabID isEqualToString:@"like"]) return LOC(@"LIKE_TAB");
    if ([tabID isEqualToString:@"live"]) return LOC(@"LIVE_TAB");
    if ([tabID isEqualToString:@"post"]) return LOC(@"POST_TAB");
    if ([tabID isEqualToString:@"video"]) return LOC(@"VIDEO_TAB");
    if ([tabID isEqualToString:@"movie"]) return LOC(@"MOVIE_TAB");
    if ([tabID isEqualToString:@"course"]) return LOC(@"COURSE_TAB");
    if ([tabID isEqualToString:@"minigame"]) return LOC(@"MINIGAME_TAB");
    if ([tabID isEqualToString:@"fashion"]) return LOC(@"FASHION_TAB");
    if ([tabID isEqualToString:@"learning"]) return LOC(@"LEARNING_TAB");
    if ([tabID isEqualToString:@"downloads"]) return LOC(@"DOWNLOADS_TAB");
    if ([tabID isEqualToString:@"home"]) return LOC(@"HOME_TAB");
    if ([tabID isEqualToString:@"shorts"]) return LOC(@"SHORTS_TAB");
    if ([tabID isEqualToString:@"subscriptions"]) return LOC(@"SUBSCRIPTIONS_TAB");
    if ([tabID isEqualToString:@"library"]) return LOC(@"LIBRARY_TAB");
    return nil;
}

static void YMApplyTabOrder(YTIPivotBarRenderer *renderer) {
    NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:TabOrder];
    if (savedOrder.count > 0) {
        NSMutableArray <YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];

        // Build lookup: pivotIdentifier -> renderer item
        NSMutableDictionary<NSString *, YTIPivotBarSupportedRenderers *> *lookup = [NSMutableDictionary dictionary];
        for (YTIPivotBarSupportedRenderers *item in items) {
            NSString *pID = [[item pivotBarItemRenderer] pivotIdentifier];
            NSString *pID2 = [[item pivotBarIconOnlyItemRenderer] pivotIdentifier];
            if (pID) lookup[pID] = item;
            if (pID2) lookup[pID2] = item;
        }

        // Build ordered array from saved data
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSDictionary *entry in savedOrder) {
            NSString *tabID = entry[@"id"];
            BOOL enabled = [entry[@"enabled"] boolValue];
            if (!enabled) continue;

            NSString *pivotID = ymPivotIDForTabID(tabID);
            if (!pivotID) continue;

            YTIPivotBarSupportedRenderers *existing = lookup[pivotID];
            if (existing) {
                [ordered addObject:existing];
            } else {
                // Custom tab not in YouTube's default items — create it
                NSInteger iconType = ymIconTypeForTabID(tabID);
                NSString *title = ymTitleForTabID(tabID);
                if (iconType > 0 && title) {
                    YTIPivotBarSupportedRenderers *newTab = [%c(YTIPivotBarRenderer) pivotSupportedRenderersWithBrowseId:pivotID title:title iconType:iconType];
                    if (newTab) [ordered addObject:newTab];
                }
            }
        }
        // Replace items with ordered set
        [items removeAllObjects];
        [items addObjectsFromArray:ordered];
    }
}

%hook YTPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    YMApplyTabOrder(renderer);
    %orig(renderer);
}
%end

// 21.44+: floating tab bar (separate class) needs the same tab ordering
%hook YTFloatingPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    YMApplyTabOrder(renderer);
    %orig(renderer);
}
%end


// Hide Tab Bar Indicators
%hook YTPivotBarIndicatorView
- (void)setFillColor:(UIColor *)arg1 {
    UIColor *temp = IS_ENABLED(HideTabIndi) ? [UIColor clearColor] : arg1;
    %orig(temp);
}
- (void)setBorderColor:(UIColor *)arg1 {
    UIColor *temp = IS_ENABLED(HideTabIndi) ? [UIColor clearColor] : arg1;
    %orig(temp);
}
%end

static __weak YTPivotBarViewController *ymPivotBarViewController;

UIView *YMDownloadsTabPivotBarView(void) {
    YTPivotBarViewController *pivot = ymPivotBarViewController;
    if (!pivot.isViewLoaded) return nil;
    return [pivot respondsToSelector:@selector(pivotBarView)] ? [pivot pivotBarView] : pivot.view;
}

static BOOL YMIsDownloadsItem(id item) {
    return [item respondsToSelector:@selector(pivotIdentifier)] && [[item pivotIdentifier] isEqualToString:YMDownloadsPivotIdentifier];
}

static void YMCacheDownloadsTab(YTPivotBarViewController *pivot) {
    Ivar ivar = class_getInstanceVariable(object_getClass(pivot), "_viewControllersCache");
    NSMutableDictionary *cache = ivar ? object_getIvar(pivot, ivar) : nil;
    if (![cache isKindOfClass:NSMutableDictionary.class]) return;
    if (!cache[YMDownloadsPivotIdentifier]) cache[YMDownloadsPivotIdentifier] = @[YMDownloadsTabViewController()];
}

// Switches to the Downloads tab when it is in the bar; returns NO otherwise.
static BOOL YMSelectDownloadsTab(YTPivotBarViewController *pivot) {
    if (!pivot || ![pivot respondsToSelector:@selector(pivotBarItemForIdentifier:)]) return NO;
    id item = [pivot pivotBarItemForIdentifier:YMDownloadsPivotIdentifier];
    if (!item) return NO;
    if (![pivot.pivotIdentifier isEqualToString:YMDownloadsPivotIdentifier]) {
        YMCacheDownloadsTab(pivot);
        [pivot selectItemWithPivotBarItem:item];
    }
    return YES;
}

static NSString *YMExtractYouTubeVideoID(NSString *urlString) {
    if (!urlString || urlString.length == 0) return nil;

    NSString *cleanString = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (cleanString.length == 11 && ![cleanString containsString:@"/"] && ![cleanString containsString:@"?"]) {
        return cleanString;
    }

    NSString *extractedID = nil;
    NSURL *url = [NSURL URLWithString:cleanString];

    if (url) {
        if ([url.host containsString:@"youtu.be"]) {
            NSString *path = [url.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
            if (path.length >= 11) {
                extractedID = [path substringToIndex:11];
            }
        } else if ([url.host containsString:@"youtube.com"]) {
            if ([url.path containsString:@"/shorts/"] || [url.path containsString:@"/live/"] || [url.path containsString:@"/clip/"]) {
                NSString *lastPath = [url.path lastPathComponent];
                if ([lastPath containsString:@"?"]) {
                    lastPath = [[lastPath componentsSeparatedByString:@"?"] firstObject];
                }
                if (lastPath.length >= 11) {
                    extractedID = [lastPath substringToIndex:11];
                }
            } else {
                NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
                for (NSURLQueryItem *item in components.queryItems) {
                    if ([item.name isEqualToString:@"v"] && item.value.length >= 11) {
                        extractedID = [item.value substringToIndex:11];
                        break;
                    }
                }
            }
        }
    }

    if (!extractedID) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:v=|\\/(?:shorts|live|clip)\\/|youtu\\.be\\/)([a-zA-Z0-9_-]{11})"
                                                                                options:NSRegularExpressionCaseInsensitive
                                                                                  error:&error];
        NSTextCheckingResult *match = [regex firstMatchInString:cleanString options:0 range:NSMakeRange(0, cleanString.length)];
        if (match && match.numberOfRanges > 1) {
            extractedID = [cleanString substringWithRange:[match rangeAtIndex:1]];
        }
    }

    return (extractedID && extractedID.length == 11) ? extractedID : nil;
}

static NSString *gLastOpenedVideoID = nil;

static void YMOpenLinkFromClipboard(UIViewController *presentingVC, BOOL isRuntime) {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    
    if (![pasteboard hasStrings]) return;

    NSString *rawString = [pasteboard.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *videoID = YMExtractYouTubeVideoID(rawString);

    if (!videoID || videoID.length == 0) return;

    if (gLastOpenedVideoID && [gLastOpenedVideoID isEqualToString:videoID] && IS_ENABLED(AutoOpenLink) && !isRuntime) return;

    NSString *schemeURLString = [NSString stringWithFormat:@"youtube://%@", videoID];
    NSURL *targetURL = [NSURL URLWithString:schemeURLString];

    if ([[UIApplication sharedApplication] canOpenURL:targetURL]) {
        gLastOpenedVideoID = [videoID copy];
        [[UIApplication sharedApplication] openURL:targetURL options:@{} completionHandler:nil];
    }
}

static void YMUpdateFloatBarLabel(YTPivotBarItemView *item);
static BOOL isGestureRegistered = NO;
// Hide Tab Labels + long-press on the first tab to open Manage Tabs
%hook YTPivotBarItemView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    %orig;
    if (IS_ENABLED(HideTabLabels)) {
        [self.navigationButton setTitle:@"" forState:UIControlStateNormal];
        self.navigationButton.titleLabel.text = @"";
        self.navigationButton.titleLabel.hidden = YES;
        [self.navigationButton setSizeWithPaddingAndInsets:NO];
    }
    // Attach long-press gesture once per view; the action handler checks the
    // current pivotIdentifier at fire time, so cell reuse / pivot bar refresh
    // can rebind the same view to a different tab safely.
    static const void *kYMContextMenuKey = &kYMContextMenuKey;
    if (!objc_getAssociatedObject(self, kYMContextMenuKey) && !isGestureRegistered) {
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:(id<UIContextMenuInteractionDelegate>)self];
        [self addInteraction:interaction];
        objc_setAssociatedObject(self, kYMContextMenuKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        isGestureRegistered = YES;
    }
}
// setRenderer: clearing the title doesn't always stick - something re-derives
// the button's title from the renderer model on a later layout pass, which is
// why the label was reappearing crammed next to the icon instead of in its
// normal (now-collapsed) spot below it. Re-assert on every layout too.
- (void)layoutSubviews {
    %orig;
    YMUpdateFloatBarLabel(self);
    if (IS_ENABLED(HideTabLabels) && self.navigationButton.titleLabel.text.length > 0) {
        [self.navigationButton setTitle:@"" forState:UIControlStateNormal];
        self.navigationButton.titleLabel.text = @"";
        self.navigationButton.titleLabel.hidden = YES;
    }
}
%new
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        UIAction *tabBarAction = [UIAction actionWithTitle:LOC(@"MANAGE_TABS")
                                                     image:[UIImage systemImageNamed:@"dock.rectangle"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction * _Nonnull action) {
            YMPresentTabOrderModally(nil);
        }];
        UIAction *openLinkAction = [UIAction actionWithTitle:LOC(@"OPEN_LINK")
                                               image:[UIImage systemImageNamed:@"link"]
                                          identifier:nil
                                             handler:^(__kindof UIAction * _Nonnull action) {
            UIViewController *topVC = YouModTopViewController(nil);
            YMOpenLinkFromClipboard(topVC, YES);
        }];
        UIAction *downloadsAction = [UIAction actionWithTitle:LOC(@"DOWNLOADS")
                                                        image:[UIImage systemImageNamed:@"arrow.down.circle"]
                                                   identifier:nil
                                                      handler:^(__kindof UIAction * _Nonnull action) {
            if (!YMSelectDownloadsTab(ymPivotBarViewController)) YMPresentDownloadsViewController(nil);
        }];
        return [UIMenu menuWithTitle:@"" children:@[tabBarAction, downloadsAction, openLinkAction]];
    }];
}
%end

// ---------------------------------------------------------------------------
// Tab bar style (YouTube 21.44+)
//   +[YTFloatingBarExperiment enableFloatingBottomBar] is read by YTPivotBarViewController -loadView to pick
//   YTFloatingPivotBarView vs the legacy YTPivotBarView, so it must be decided before the tab bar loads
//   (a style change needs an app restart).  +isIconsOnly drives the label of the floating bar items.
// ---------------------------------------------------------------------------
// Read once: these are queried from hot paths (layout passes, YouTube's config getters) and a style
// change needs a restart anyway.
static NSInteger YMTabBarStyle(void) {
    static NSInteger style;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ style = INTFORVAL(TabBarStyle); });
    return style;
}
static BOOL YMHybridBar(void) { return YMTabBarStyle() == 3; }

%hook YTFloatingBarExperiment
+ (BOOL)enableFloatingBottomBar {
    switch (YMTabBarStyle()) {
        case 1: case 3: return YES;
        case 2: return NO;
        default: return %orig;
    }
}
%end

%hook YTColdConfig
// Hybrid relies on YouTube's scroll-driven hide/show calls
- (BOOL)iosEnableNonStickyPivotBar { return YMHybridBar() ? YES : %orig; }
- (BOOL)mainAppCoreClientHidePivotBarOnScrollInTabs { return YMHybridBar() ? YES : %orig; }
%end

// Floating bar labels. YouTube builds the floating bar icon-only whatever the config says, so the label is
// drawn here: the icon moves up and a small label (the item's accessibility label) goes under it.
static const void *kYMFloatLabelKey = &kYMFloatLabelKey;
static void YMUpdateFloatBarLabel(YTPivotBarItemView *item) {
    UILabel *label = objc_getAssociatedObject(item, kYMFloatLabelKey);
    UIView *button = item.navigationButton;
    BOOL floating = item.superview.superview && [item.superview.superview isKindOfClass:%c(YTFloatingPivotBarView)];
    if (!floating || !IS_ENABLED(FloatBarLabels) || item.bounds.size.width < 1 || !button.accessibilityLabel.length) {
        label.hidden = YES;
        button.transform = CGAffineTransformIdentity;
        return;
    }
    if (!label) {
        label = [UILabel new];
        label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.7;
        objc_setAssociatedObject(item, kYMFloatLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item addSubview:label];
    }
    label.hidden = NO;
    label.text = button.accessibilityLabel;
    label.textColor = UIColor.labelColor;
    label.frame = CGRectMake(4, item.bounds.size.height - 19, item.bounds.size.width - 8, 13);
    button.transform = CGAffineTransformMakeTranslation(0, -8);
    [item bringSubviewToFront:label];
}

// Hybrid: instead of hiding the floating bar while scrolling down, morph it into a docked (edge to edge) bar
// and morph it back while scrolling up.  Only the contentView transform is touched, so it does not depend on
// how YouTube lays the capsule out.
static __weak YTFloatingPivotBarView *gYMFloatBar = nil;
static CGFloat gYMDock = 0;                    // 0 = floating, 1 = docked
static BOOL gYMInScrollPivotUpdate = NO;
static const void *kYMDockBackdropKey = &kYMDockBackdropKey;
static const void *kYMDockRadiusKey = &kYMDockRadiusKey;

// Corner radius lerp: remember YouTube's own radius (re-read whenever YouTube changes it) per view
static const void *kYMDockLastKey = &kYMDockLastKey;
static CGFloat YMBaseRadius(UIView *v) {
    NSNumber *base = objc_getAssociatedObject(v, kYMDockRadiusKey);
    NSNumber *last = objc_getAssociatedObject(v, kYMDockLastKey);
    CGFloat cur = v.layer.cornerRadius;
    if (!base || !last || fabs(cur - last.doubleValue) > 0.01) {
        base = @(cur);
        objc_setAssociatedObject(v, kYMDockRadiusKey, base, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return base.doubleValue;
}

static void YMSetRadius(UIView *v, CGFloat factor) {
    CGFloat base = YMBaseRadius(v);
    if (base <= 0) return;
    CGFloat r = base * factor;
    v.layer.cornerRadius = r;
    objc_setAssociatedObject(v, kYMDockLastKey, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The whole bar view is transformed (it is the capsule: the blur background and contentView are its sibling
// subviews, so transforming contentView alone only moved the icons). Called with the bar laid out untransformed.
static void YMApplyDock(YTFloatingPivotBarView *bar, CGFloat p) {
    UIWindow *win = bar.window;
    UIView *host = bar.superview;
    if (!win || !host) return;
    UIView *cv = [bar respondsToSelector:@selector(contentView)] ? bar.contentView : nil;
    UIVisualEffectView *backdrop = objc_getAssociatedObject(bar, kYMDockBackdropKey);

    NSMutableArray<UIView *> *rounded = [NSMutableArray arrayWithObject:bar];
    [rounded addObjectsFromArray:bar.subviews];

    if (p < 0.001) {
        bar.transform = CGAffineTransformIdentity;
        for (UIView *v in cv.subviews) v.transform = CGAffineTransformIdentity;
        for (UIView *v in rounded) YMSetRadius(v, 1.0);
        backdrop.alpha = 0;
        return;
    }

    CGRect r = [host convertRect:bar.frame toView:nil];   // bar is untransformed here
    if (r.size.width < 1 || r.size.height < 1) return;
    CGFloat winW = win.bounds.size.width, winH = win.bounds.size.height;
    CGFloat safeBottom = win.safeAreaInsets.bottom;
    CGFloat fullScale = MIN(MAX(winW / r.size.width, 1.0), 1.6);
    CGFloat sx = 1.0 + (fullScale - 1.0) * p;
    CGFloat dx = (winW / 2.0 - CGRectGetMidX(r)) * p;
    CGFloat dy = MAX(0, (winH - safeBottom) - CGRectGetMaxY(r)) * p;

    for (UIView *v in rounded) YMSetRadius(v, 1.0 - p);
    bar.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(sx, 1.0), CGAffineTransformMakeTranslation(dx, dy));
    // keep icons, labels and the selection pill undistorted while the capsule spreads
    for (UIView *v in cv.subviews) v.transform = CGAffineTransformMakeScale(1.0 / sx, 1.0);

    // fill the home-indicator area like the legacy bar does
    if (safeBottom > 0) {
        if (!backdrop) {
            backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
            backdrop.userInteractionEnabled = NO;
            objc_setAssociatedObject(bar, kYMDockBackdropKey, backdrop, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        // OLED theme: a blur over black reads grey, so paint the area solid black instead
        BOOL oled = IS_ENABLED(OLEDTheme) && win.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        backdrop.effect = oled ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
        backdrop.backgroundColor = oled ? [UIColor blackColor] : nil;
        if (backdrop.superview != host) [host insertSubview:backdrop belowSubview:bar];
        CGPoint origin = [host convertPoint:CGPointMake(0, winH - safeBottom) fromView:nil];
        backdrop.frame = CGRectMake(0, origin.y - 1, host.bounds.size.width, safeBottom + 1 + 200);
        backdrop.alpha = p;
    }
}

static void YMSetBarDocked(BOOL docked) {
    YTFloatingPivotBarView *bar = gYMFloatBar;
    if (!bar) return;
    CGFloat target = docked ? 1.0 : 0.0;
    if (gYMDock == target) return;
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.0
                        options:(UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        gYMDock = target;
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    } completion:nil];
}

%hook YTFloatingPivotBarView
- (void)layoutSubviews {
    BOOL touched = YMHybridBar() || gYMDock > 0;
    UIView *cv = (touched && [self respondsToSelector:@selector(contentView)]) ? self.contentView : nil;
    // let YouTube lay out with an untouched capsule, then re-apply the dock transform
    if (touched) {
        self.transform = CGAffineTransformIdentity;
        for (UIView *v in cv.subviews) v.transform = CGAffineTransformIdentity;
    }
    %orig;
    gYMFloatBar = self;
    if (touched) YMApplyDock(self, YMHybridBar() ? gYMDock : 0);
}
%end

%hook YTScrollableNavigationController
- (void)updatePivotBarVisibilityForScrollView:(id)scrollView contentOffsetY:(CGFloat)y isAtBottom:(BOOL)atBottom {
    BOOL prev = gYMInScrollPivotUpdate;
    gYMInScrollPivotUpdate = YMHybridBar() && gYMFloatBar != nil;
    %orig;
    gYMInScrollPivotUpdate = prev;
}
%end

%hook YTAppView
- (void)hidePivotBar {
    if (gYMInScrollPivotUpdate) { YMSetBarDocked(YES); return; }
    %orig;
}
- (void)showPivotBar {
    if (gYMInScrollPivotUpdate) { YMSetBarDocked(NO); return; }
    %orig;
    if (YMHybridBar()) YMSetBarDocked(NO);
}
%end

// Startup Tab
static BOOL isTabSelected = NO;
%hook YTPivotBarViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    ymPivotBarViewController = self;
    sbUpdateOverlayInsetForPivotBar();
    if (IS_ENABLED(ShortsOnly) && !isTabSelected) {
        [self selectItemWithPivotIdentifier:@"FEshorts"];
        isTabSelected = YES;
        return;
    }
    if (!isTabSelected) {
        // Build pivot identifiers from enabled tabs (skip Create — matches Settings.x segment logic)
        NSMutableArray *pivotIdentifiers = [NSMutableArray array];
        NSArray *savedOrder = [[NSUserDefaults standardUserDefaults] arrayForKey:TabOrder];
        if (savedOrder.count > 0) {
            for (NSDictionary *entry in savedOrder) {
                if (![entry[@"enabled"] boolValue]) continue;
                NSString *tabID = entry[@"id"];
                if ([tabID isEqualToString:@"create"] || [tabID isEqualToString:@"downloads"]) continue;
                NSString *pivot = ymPivotIDForTabID(tabID);
                if (pivot) [pivotIdentifiers addObject:pivot];
            }
        }
        if (pivotIdentifiers.count == 0) {
            pivotIdentifiers = [@[@"FEwhat_to_watch", @"FEshorts", @"FEsubscriptions", @"FElibrary"] mutableCopy];
        }

        NSInteger tabIndex = INTFORVAL(DefaultTab);
        if (tabIndex < 0) tabIndex = 0;
        if (tabIndex >= (NSInteger)pivotIdentifiers.count) tabIndex = MAX(0, (NSInteger)pivotIdentifiers.count - 1);
        [self selectItemWithPivotIdentifier:pivotIdentifiers[tabIndex]];
        isTabSelected = YES;
    }
}
// The Downloads tab. YouTube switches tabs in -selectItemWithPivotBarItem:: it
// caches the current tab's view controllers, then shows the cached stack of the
// tapped tab (_viewControllersCache[pivotIdentifier]) or, with nothing cached,
// loads the item's browse page. Keeping YouMod's screen in that cache makes the
// Downloads item a real tab - selected in the bar and kept while switching -
// without a browse page behind it.
- (void)didTapItemWithRenderer:(YTIPivotBarItemRenderer *)renderer {
    if (YMIsDownloadsItem(renderer)) {
        if ([self.pivotIdentifier isEqualToString:YMDownloadsPivotIdentifier]) {
            YMDownloadsTabReturnToTop(YMDownloadsTabViewController());
            return;
        }
        YMCacheDownloadsTab(self);
        [self selectItemWithPivotBarItem:renderer];
        return;
    }
    %orig;
}
- (void)selectItemWithPivotBarItem:(id)item {
    if (YMIsDownloadsItem(item)) YMCacheDownloadsTab(self);
    %orig;
}
// The item is built as a browse endpoint, so catch it on the navigation path too.
- (BOOL)handlePivotBarNavigationCommand:(YTICommand *)command {
    if ([command respondsToSelector:@selector(browseEndpoint)] && [command.browseEndpoint.browseId isEqualToString:YMDownloadsPivotIdentifier]) {
        YMSelectDownloadsTab(self);
        return YES;
    }
    return %orig;
}
// A cleared cache (account switch, memory warning) would send the next tap to the
// nonexistent browse page.
- (void)resetViewControllersCache {
    %orig;
    YMCacheDownloadsTab(self);
}
- (void)resetViewControllersCacheForPivotIdentifiers:(id)identifiers {
    %orig;
    YMCacheDownloadsTab(self);
}
// Translucent tab bar
- (BOOL)isFrostedPivotBarPermitted {
    if (INTFORVAL(UseFrostedTabBar) == 1) {
        return YES;
    } else if (INTFORVAL(UseFrostedTabBar) == 2) {
        return NO;
    }
    return %orig;
}
%end

%hook YTAppDelegate
- (void)appDidBecomeActive {
    %orig;
    if (IS_ENABLED(AutoOpenLink)) {
        UIViewController *topVC = YouModTopViewController(nil);
        YMOpenLinkFromClipboard(topVC, NO);
    }
    if (IS_ENABLED(HideSubbar)) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"YouModReloadHeaderBar" object:nil];
    }
}
%end

// Always show tab bar: turn off only YouTube's hide-on-scroll. Blocking -hidePivotBar
// itself also kept the bar up while the watch player expands, and the page under the
// player was then laid out against the wrong bounds - after minimizing, a playlist
// page's list sat shifted left with a blank strip on the right.
%hook YTScrollableNavigationController
// Hybrid tab bar needs YouTube's scroll hide/show calls, so it wins over "Always show tab bar"
- (BOOL)hidePivotBarOnScroll { return (IS_ENABLED(PinTabBar) && !YMHybridBar()) ? NO : %orig; }
- (void)setHidePivotBarOnScroll:(BOOL)hide { %orig((IS_ENABLED(PinTabBar) && !YMHybridBar()) ? NO : hide); }
%end

// Recompute SB overlay safe-area inset whenever YouTube shows or hides the pivot bar
// (e.g. entering/exiting fullscreen player). This keeps the SponsorBlock skip pill
// and download progress pill anchored above the tabbar when visible, and at the
// device safe-area bottom when the tabbar is hidden.
%hook YTAppViewController
- (void)hidePivotBar {
    %orig;
    sbUpdateOverlayInsetForPivotBar();
}
- (void)showPivotBar {
    %orig;
    sbUpdateOverlayInsetForPivotBar();
}
%end

%hook YTAppViewControllerImpl
- (void)hidePivotBar {
    if (gYMInScrollPivotUpdate) { YMSetBarDocked(YES); return; }
    %orig;
    sbUpdateOverlayInsetForPivotBar();
}
- (void)showPivotBar {
    if (gYMInScrollPivotUpdate) { YMSetBarDocked(NO); return; }
    %orig;
    if (YMHybridBar()) YMSetBarDocked(NO);
    sbUpdateOverlayInsetForPivotBar();
}
%end
