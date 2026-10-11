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

%hook YTHeaderView
- (BOOL)stickyNavHeaderEnabled { 
    if (IS_ENABLED(StickyNavBar)) {
        [self setStickyNavHeaderEnabled:YES];
        return YES;
    }
    return %orig;
}
%end