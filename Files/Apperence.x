#import "Headers.h"
#import <objc/runtime.h>

// Shared dynamic colors for the OLED theme. These used to be built per view with a
// provider block that captured the view itself (view -> backgroundColor -> block ->
// view), a retain cycle that leaked every themed view in the app. The resolving trait
// collection passed to the provider already carries the view's style.
static UIColor *YMOLEDBlackOrClear(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor blackColor] : [UIColor clearColor];
        }];
    });
    return color;
}

static UIColor *YMOLEDBlackOrWhite(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        color = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor blackColor] : [UIColor whiteColor];
        }];
    });
    return color;
}

%group OLEDTheme
%hook YTColor
+ (UIColor *)black0 { return [UIColor blackColor]; }
+ (UIColor *)black1 { return [UIColor blackColor]; }
+ (UIColor *)black2 { return [UIColor blackColor]; }
+ (UIColor *)black3 { return [UIColor blackColor]; }
+ (UIColor *)black4 { return [UIColor blackColor]; }
%end

%hook YTCommonColorPalette
- (UIColor *)baseBackground { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)brandBackgroundSolid { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)brandBackgroundPrimary { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)brandBackgroundSecondary { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)raisedBackground { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)staticBrandBlack { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
- (UIColor *)generalBackgroundA { return self.pageStyle == 1 ? [UIColor blackColor] : %orig; }
%end

%hook YTInnerTubeCollectionViewController
- (UIColor *)backgroundColor:(NSInteger)pageStyle { return pageStyle == 1 ? [UIColor blackColor] : %orig; }
%end

// _ASDisplayView backs every Texture node in the whole app, so this hook runs on
// every single view's window attachment everywhere, not just OLED-theme-relevant
// ones - a real cost during any big reflow (e.g. the whole watch-next feed
// rebuilding when fullscreen is exited). The NSSet used to be rebuilt from scratch
// on every call instead of once; hoisted to static. The "filter_chip_bar" check
// further down doesn't need the expensive _viewControllerForAncestor walk at all,
// so it's moved ahead of it to skip that walk for the common case.
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    static NSSet *blackViews = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blackViews = [NSSet setWithObjects:
            @"id.elements.components.comment_composer",
            @"id.subs.subscriptions_channel_bar",
            @"PAmedia_hub_device_picker.engagement_panel_header", nil
        ];
    });
    if ([blackViews containsObject:self.accessibilityIdentifier]) {
        self.backgroundColor = YMOLEDBlackOrClear();
        return;
    }
    if ([self.accessibilityIdentifier isEqualToString:@"id.elements.components.filter_chip_bar"]) {
        UIColor *dynamicColor = YMOLEDBlackOrClear();
        self.backgroundColor = dynamicColor;
        self.superview.backgroundColor = dynamicColor;
        return;
    }
    UIViewController *controller = self._viewControllerForAncestor;
    if ([controller isKindOfClass:%c(YTActionSheetDialogViewController)] || [controller isKindOfClass:%c(YTBottomSheetController)]) {
        if ([self.superview.accessibilityIdentifier isEqualToString:@"eml.animated_subscribe_button"]) return;
        self.backgroundColor = YMOLEDBlackOrClear();
        return;
    } else if ([self.accessibilityIdentifier isEqualToString:@"eml.live_chat_text_message"] && [controller isKindOfClass:%c(YCHAsyncLiveChatCollectionViewController)]) {
        YCHAsyncLiveChatCollectionViewController *con = (YCHAsyncLiveChatCollectionViewController *)controller;
        if ([con.view isKindOfClass:%c(YCHAsyncLiveChatImmersiveCollectionView)]) return;
        self.backgroundColor = YMOLEDBlackOrWhite();
        return;
    } else if ([controller isKindOfClass:%c(YTELMViewController)]) {
        // Most of YouTube's UI lives in ELM controllers, and the renderer's
        // -description is a full protobuf text dump - so classify each controller
        // once (cached per controller and renderer) instead of per child view.
        YTELMViewController *con = (YTELMViewController *)controller;
        YTIElementRenderer *renderer = [con valueForKey:@"_renderer"];
        static const void *kYMOLEDRendererKey = &kYMOLEDRendererKey;
        static const void *kYMOLEDKindKey = &kYMOLEDKindKey;
        NSInteger kind;
        if (objc_getAssociatedObject(con, kYMOLEDRendererKey) == renderer) {
            kind = [objc_getAssociatedObject(con, kYMOLEDKindKey) integerValue];
        } else {
            NSString *desc = [renderer description];
            kind = 0;
            if ([desc containsString:@"timeline_search_input_form_id"] && [desc containsString:@"search_input.eml"]) kind |= 1;
            if ([desc containsString:@"transcript_panel.eml"]) kind |= 2;
            objc_setAssociatedObject(con, kYMOLEDRendererKey, renderer, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(con, kYMOLEDKindKey, @(kind), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ((kind & 1) && [self.accessibilityIdentifier isEqualToString:@"id.elements.components.text_field"]) {
            self.superview.backgroundColor = YMOLEDBlackOrClear();
        } else if (kind & 2) {
            self.backgroundColor = YMOLEDBlackOrClear();
        }
        return;
    }
}
%end

%hook ASCollectionView
- (void)didMoveToWindow {
    %orig;
    static NSSet *blackViews = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blackViews = [NSSet setWithObjects:
            @"eml.chip_bar_collection",
            @"subs_channel_bar.collection", nil
        ];
    });
    if ([blackViews containsObject:self.accessibilityIdentifier]) {
        self.backgroundColor = YMOLEDBlackOrClear();
    }
    if ([self.accessibilityIdentifier isEqualToString:@"subs_channel_bar.collection"]) {
        self.backgroundColor = YMOLEDBlackOrClear();
    }
    if ([self.accessibilityIdentifier isEqualToString:@"id.elements.components.more_drawer_collection"]) {
        self.superview.backgroundColor = YMOLEDBlackOrWhite();
    }
}
%end

%hook YTContextualWrapView
- (void)didMoveToWindow {
    %orig;
    UIView *sup = self.superview;
    if ([sup isKindOfClass:%c(YTContextualSheetView)]) {
        self.backgroundColor = YMOLEDBlackOrWhite();
    }
}
%end

%hook ASScrollView
- (void)didMoveToWindow {
    %orig;
    ASDisplayNode *node = self.scrollNode;
    if (node) {
        for (UIView *child in node.yogaChildren) {
            NSString *desc = [child description];
            if ([desc containsString:@"id.elements.components.report_form_reason_select_page.container"] || [desc containsString:@"id.elements.components.report_form_sign_in_page.container"]) {
                self.backgroundColor = YMOLEDBlackOrClear();
                break;
            }
        }
    } 
}
%end

%hook MDCInkView
- (void)didMoveToWindow {
    %orig;
    if ([self.superview isKindOfClass:%c(GOODialogActionMDCButton)]) {
        UIViewController *controller = self._viewControllerForAncestor;
        if ([controller isKindOfClass:%c(YTBottomSheetController)] || [controller isKindOfClass:%c(GOOModalWindowViewController)]) return;
        self.backgroundColor = YMOLEDBlackOrClear();
    }
}
%end

%hook YTStartupAnimationViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *mainView = self.view;
    mainView.backgroundColor = YMOLEDBlackOrWhite();
}
%end

%hook YTEngagementPanelView
- (void)setFooterView:(UIView *)view {
    %orig;
    if (view) {
        UIView *sub = view.subviews.firstObject;
        sub.backgroundColor = YMOLEDBlackOrClear();
    }
}
%end
%end

// OLED Keyboard
//
// Why it never worked: the keyboard's look is driven by the text input's
// keyboardAppearance, and YouTube's text fields leave it at Default, which follows
// the *system* style, not YouTube's in-app theme. With YouTube on its dark theme and
// iOS in light mode the keyboard came up light, every hook below saw "not dark", and
// nothing was ever painted. So: track YouTube's real page style
// (YTPageStyleControllerImpl, 1 = dark - the same value OLEDTheme keys off), force
// the keyboard to the dark appearance while YouTube is dark, and only then paint
// the keyboard's backgrounds black.
static NSInteger ymAppPageStyle = -1;

static BOOL YMAppIsDark(void) {
    if (ymAppPageStyle >= 0) return ymAppPageStyle == 1;
    // Page style not reported yet - fall back to the app's own (non-keyboard) window.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSString *name = NSStringFromClass(window.class);
        if ([name containsString:@"Keyboard"] || [name containsString:@"TextEffects"]) continue;
        return window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

// The keyboard window doesn't inherit YouTube's overrideUserInterfaceStyle, so read
// the style the keyboard itself was built with (its input view controller's traits).
static BOOL OLEDKeyboardIsDarkMode(UIView *view) {
    if (YMAppIsDark()) return YES; // keyboardAppearance is forced dark below in this case
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return ((UIViewController *)responder).traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
        responder = [responder nextResponder];
    }
    return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
}

// Keyboard backgrounds the per-class hooks below don't reach (the backdrop/glass
// views differ between iOS versions - e.g. iOS 26's glass keyboard). Only ever walks
// the keyboard's own windows, and only on keyboard show/frame-change notifications,
// never per layout pass.
static void YMOLEDPaintKeyboardView(UIView *view, NSUInteger depth) {
    if (depth > 12) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL isBackground = [name containsString:@"Backdrop"] || [name hasPrefix:@"UIKBVisualEffect"]
        || ([name containsString:@"Glass"] && [name containsString:@"Background"])
        || [name isEqualToString:@"UIKeyboardDockView"];
    if (isBackground) {
        if ([view isKindOfClass:[UIVisualEffectView class]]) ((UIVisualEffectView *)view).effect = nil;
        view.backgroundColor = [UIColor blackColor];
    }
    for (UIView *sub in view.subviews) YMOLEDPaintKeyboardView(sub, depth + 1);
}

static void YMOLEDPaintKeyboardWindows(void) {
    if (!YMAppIsDark()) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSString *name = NSStringFromClass(window.class);
        if (![name containsString:@"Keyboard"] && ![name containsString:@"TextEffects"]) continue;
        YMOLEDPaintKeyboardView(window, 0);
    }
}

%group OLEDKeyboard
%hook YTPageStyleControllerImpl
- (NSInteger)pageStyle {
    NSInteger style = %orig;
    ymAppPageStyle = style;
    return style;
}
- (void)setPageStyle:(NSInteger)style {
    %orig;
    ymAppPageStyle = style;
}
%end

%hook UITextField
- (UIKeyboardAppearance)keyboardAppearance {
    return YMAppIsDark() ? UIKeyboardAppearanceDark : %orig;
}
%end

%hook UITextView
- (UIKeyboardAppearance)keyboardAppearance {
    return YMAppIsDark() ? UIKeyboardAppearanceDark : %orig;
}
%end

%hook UIKeyboard
- (void)displayLayer:(id)arg1 {
    %orig;
    self.backgroundColor = OLEDKeyboardIsDarkMode(self) ? [UIColor blackColor] : [UIColor clearColor];
}
%end

%hook UIPredictionViewController
- (id)_currentTextSuggestions {
    UIKeyboard *keyboard = [%c(UIKeyboard) activeKeyboard];
    UIColor *color = OLEDKeyboardIsDarkMode(keyboard) ? [UIColor blackColor] : [UIColor clearColor];
    [self.view setBackgroundColor:color];
    keyboard.backgroundColor = color;
    return %orig;
}
%end

%hook UIKeyboardDockView
- (void)layoutSubviews {
    %orig;
    self.backgroundColor = OLEDKeyboardIsDarkMode(self) ? [UIColor blackColor] : [UIColor clearColor];
}
%end

// Since we can't hook a private framework class from UIKit, we check the class name through the nearest available from UIKit class
%hook UIInputView
- (void)layoutSubviews {
    %orig;
    if ([self isKindOfClass:NSClassFromString(@"TUIEmojiSearchInputView")] || [self isKindOfClass:NSClassFromString(@"_SFAutoFillInputView")]) {
        self.backgroundColor = OLEDKeyboardIsDarkMode(self) ? [UIColor blackColor] : [UIColor clearColor];
    }
}
%end

%hook UIKBVisualEffectView
- (void)layoutSubviews {
    %orig;
    if (OLEDKeyboardIsDarkMode(self)) {
        if ([self respondsToSelector:@selector(setBackgroundEffects:)]) {
            @try { self.backgroundEffects = nil; } @catch (NSException *e) {}
        }
        self.backgroundColor = [UIColor blackColor];
    }
}
%end
%end

%ctor {
    YMRegisterDefaults();
    if (IS_ENABLED(OLEDTheme)) {
        %init(OLEDTheme);
    }
    if (IS_ENABLED(OLEDKeyboard)) {
        %init(OLEDKeyboard);
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        for (NSNotificationName name in @[UIKeyboardWillShowNotification, UIKeyboardDidShowNotification, UIKeyboardDidChangeFrameNotification]) {
            [center addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                YMOLEDPaintKeyboardWindows();
            }];
        }
    }
}