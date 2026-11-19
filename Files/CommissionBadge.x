#import "Headers.h"

// "Earns commission" badge on feed thumbnails: a second "eml.timestamp" pill drawn left of the duration pill. It is
// found by structure (the first of two eml.timestamp siblings), not by its label, which is translated. Switched on
// and off in settings; read at launch, so a change needs a restart.
%group HideCommissionBadge
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (!self.window || ![self.accessibilityIdentifier isEqualToString:@"eml.timestamp"]) return;
    UIView *first = nil;
    NSInteger count = 0;
    for (UIView *sibling in self.superview.subviews) {
        if (![sibling.accessibilityIdentifier isEqualToString:@"eml.timestamp"]) continue;
        if (!first) first = sibling;
        count++;
    }
    BOOL labelled = [self.accessibilityLabel.lowercaseString containsString:@"commission"];
    if ((count >= 2 && first == self) || labelled) self.hidden = YES;
}
%end
%end

%ctor {
    YMRegisterDefaults();
    if (IS_ENABLED(HideCommissionBadge)) %init(HideCommissionBadge);
}
