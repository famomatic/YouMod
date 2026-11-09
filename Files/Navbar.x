#import "Headers.h"

// YouTube Premium logo
%hook YTHeaderLogoController
- (void)setTopbarLogoRenderer:(YTITopbarLogoRenderer *)renderer {
    if (INTFORVAL(YTLogoIndex) == 0) {
        %orig;
        return;
    }
    // Modify the type of the icon before setting the renderer
    YTIIcon *icon = renderer.iconImage;
    if (icon) {
        if (INTFORVAL(YTLogoIndex) == 1) {
            icon.iconType = 537;
        } else if (INTFORVAL(YTLogoIndex) == 2) {
            icon.iconType = 158;
        }
    }
    %orig(renderer);
}
// For when spoofing before 18.34.5
- (void)setPremiumLogo:(BOOL)arg { 
    if (INTFORVAL(YTLogoIndex) == 1) {
        arg = YES;
    } else if (INTFORVAL(YTLogoIndex) == 2) {
        arg = NO;
    }
    %orig(arg);
}
- (BOOL)isPremiumLogo { 
    if (INTFORVAL(YTLogoIndex) == 1) {
        return YES;
    } else if (INTFORVAL(YTLogoIndex) == 2) {
        return NO;
    }
    return %orig;
}
%end

%hook YTHeaderLogoControllerImpl
- (void)setTopbarLogoRenderer:(YTITopbarLogoRenderer *)renderer {
    if (INTFORVAL(YTLogoIndex) == 0) {
        %orig;
        return;
    }
    // Modify the type of the icon before setting the renderer
    YTIIcon *icon = renderer.iconImage;
    if (icon) {
        if (INTFORVAL(YTLogoIndex) == 1) {
            icon.iconType = 537;
        } else if (INTFORVAL(YTLogoIndex) == 2) {
            icon.iconType = 158;
        }
    }
    %orig(renderer);
}
// For when spoofing before 18.34.5
- (void)setPremiumLogo:(BOOL)arg { 
    if (INTFORVAL(YTLogoIndex) == 1) {
        arg = YES;
    } else if (INTFORVAL(YTLogoIndex) == 2) {
        arg = NO;
    }
    %orig(arg);
}
- (BOOL)isPremiumLogo { 
    if (INTFORVAL(YTLogoIndex) == 1) {
        return YES;
    } else if (INTFORVAL(YTLogoIndex) == 2) {
        return NO;
    }
    return %orig;
}
%end

// Hide Navigation Bar Buttons
%hook YTRightNavigationButtons
- (void)layoutSubviews {
    %orig;
    if (IS_ENABLED(HideNoti)) self.notificationButton.hidden = YES;
    if (IS_ENABLED(HideSearch)) self.searchButton.hidden = YES;
    for (UIView *subview in self.subviews) {
        if (IS_ENABLED(HideVoiceSearch) && [subview.accessibilityLabel isEqualToString:NSLocalizedString(@"search.voice.access", nil)]) subview.hidden = YES;
        if (IS_ENABLED(HideCastButtonNav) && [subview.accessibilityIdentifier isEqualToString:@"id.mdx.playbackroute.button"]) subview.hidden = YES;
    }
    // Gonerino (github.com/castdrian/Gonerino, often bundled alongside YouMod by
    // the ipa.yml workflow) adds its own button here via a hardcoded
    // CGRectMake(0,0,40,40) frame rather than this view's real button-placement
    // mechanism (buttonForType:/setButton:forType:), so it lands at the
    // container's origin and overlaps whatever else sits there - usually search.
    // Since %orig has already positioned every button we DO understand (search,
    // voice search, cast, notifications) by this point, push Gonerino's button
    // to sit just left of the leftmost real button we can find instead of
    // trusting its own frame.
    UIView *gonerinoButton = nil;
    CGFloat leftmostVisibleX = CGFLOAT_MAX;
    for (UIView *subview in self.subviews) {
        if ([subview.accessibilityLabel isEqualToString:@"Gonerino"]) {
            gonerinoButton = subview;
            continue;
        }
        if (subview.hidden) continue;
        leftmostVisibleX = MIN(leftmostVisibleX, CGRectGetMinX(subview.frame));
    }
    if (gonerinoButton && leftmostVisibleX != CGFLOAT_MAX) {
        CGRect frame = gonerinoButton.frame;
        frame.origin.x = leftmostVisibleX - frame.size.width;
        frame.origin.y = (self.bounds.size.height - frame.size.height) / 2.0;
        gonerinoButton.frame = frame;
    }
}
%end

%hook YTHeaderLogoController
- (id)init {
    return INTFORVAL(YTLogoIndex) == 3 ? nil : %orig;
}
%end

%hook YTHeaderLogoControllerImpl
- (id)init {
    return INTFORVAL(YTLogoIndex) == 3 ? nil : %orig;
}
%end

%hook YTNavigationBarTitleView
- (void)didMoveToWindow {
    %orig;
    if (INTFORVAL(YTLogoIndex) == 3) {
        for (UIView *sub in self.subviews) {
            if ([sub.accessibilityIdentifier isEqualToString:@"id.yoodle.logo"] || [sub.accessibilityIdentifier isEqualToString:@"id.youtube.logo"]) {
                [sub removeFromSuperview];
                break;
            }
        }
    }
}
%end

// Pin top bar: the logo bar and the subheader under it (the Home tabs strip on 21.44+) never scroll away.
// A positive offset scrolls the header up (hides it), a negative one brings it back. The scrollable navigation
// controller drives it from the feed's scrolling and YTHeaderContentComboView from its layout; both end in
// -[YTHeaderView scrollNavHeaderViewWithOffset:], which also moves the adjacent subheader.
// (Forcing YTHeaderView's stickyNavHeaderEnabled, as this used to, kept only the logo bar: the tabs strip still
// scrolled away, and the sticky flag skips the step in -canScrollNavHeaderUp that settles an animating subheader,
// which could leave the tabs strip collapsed until a restart.)
%hook YTHeaderView
- (void)scrollNavHeaderViewWithOffset:(CGFloat)offset {
    if (IS_ENABLED(StickyNavBar) && offset > 0) return;
    %orig;
}
%end

%hook YTScrollableNavigationController
- (void)scrollNavHeaderViewWithOffset:(CGFloat)offset {
    if (IS_ENABLED(StickyNavBar) && offset > 0) return;
    %orig;
}
- (void)scrollUpAnimated:(BOOL)animated {
    if (IS_ENABLED(StickyNavBar)) return;
    %orig;
}
%end