#import "Headers.h"

// Hide Subbar
%hook YTHeaderContentComboView
- (void)enableSubheaderBarWithView:(id)arg1 { if (!IS_ENABLED(HideSubbar)) %orig; }
- (void)setFeedHeaderScrollMode:(int)arg1 { 
    int temp = IS_ENABLED(HideSubbar) ? 0 : arg1;
    %orig(temp);
}
- (id)initWithChildView:(id)arg1 headerView:(id)arg2 {
    self = %orig;
    if (self && IS_ENABLED(HideSubbar)) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(setNeedsLayout) name:@"YouModReloadHeaderBar" object:nil];
    }
    return self;
}
%end

// Hide voice search button
%hook YTSearchViewController
- (void)viewDidLoad {
    %orig;
    if (IS_ENABLED(HideVoiceSearch)) {
        [self setValue:@(NO) forKey:@"_isVoiceSearchAllowed"];
    }
}
- (void)setSuggestions:(id)arg1 { if (!IS_ENABLED(HideSearchHis)) %orig; }
%end

// Hide search history and suggestions
%hook YTPersonalizedSuggestionsCacheProvider
- (id)activeCache { return IS_ENABLED(HideSearchHis) ? nil : %orig; }
%end

// Hide related videos in the player
%hook YTWatchNextResultsViewController
- (void)setVisibleSections:(NSInteger)sections {
    if (![self.parentViewController isKindOfClass:%c(YTWatchNextResponseViewController)]) {
        %orig;
        return;
    }
    NSInteger value = IS_ENABLED(HideRelatedVideos) ? 1 : sections;
    %orig(value);
}
%end

static void YouModFilterChannelButtons(_ASDisplayView *self, NSString *iden) {
    UIView *sup = self.superview;
    if ([sup isKindOfClass:%c(ASScrollView)]) {
        ASScrollView *scroll = (ASScrollView *)sup;
        ASDisplayNode *node = scroll.scrollNode;
        for (_ASDisplayView *view in node.yogaChildren) {
            if ([[view description] containsString:iden]) {
                [node removeYogaChild:view];
                [self removeFromSuperview];
                break;
            }
        }
    } else {
        UIViewController *con = self._viewControllerForAncestor;
        if ([con isKindOfClass:%c(YTPageHeaderViewController)]) {
            _ASDisplayView *dpv = (_ASDisplayView *)sup;
            ASDisplayNode *node = dpv.keepalive_node;
            _ASDisplayView *maindpv = (_ASDisplayView *)dpv.superview;
            ASDisplayNode *mainNode = maindpv.keepalive_node;
            [mainNode removeYogaChild:node];
            [dpv removeFromSuperview];
        } else if ([con isKindOfClass:%c(YTWatchNextResultsViewController)]) {
            _ASDisplayView *dpv = (_ASDisplayView *)sup;
            ASDisplayNode *node = dpv.keepalive_node;
            for (id child in [node.yogaChildren copy]) {
                if ([[child description] containsString:iden]) {
                    [node removeYogaChild:child];
                    [self removeFromSuperview];
                    break;
                }
            }
        }
    }
}

%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    NSString *iden = self.accessibilityIdentifier;
    if (!iden || iden.length == 0) return;
    BOOL remove = NO;
    if ([iden isEqualToString:@"eml.header_community_button"] && IS_ENABLED(RemoveChannelCommunityButton)) {
        remove = YES;
    } else if ([iden isEqualToString:@"id.sponsor_button"] && IS_ENABLED(RemoveChannelSponsorAll)) {
        remove = YES;
    }
    if (remove) {
        YouModFilterChannelButtons(self, iden);
    }
}
%end
// Post images at their original aspect ratio. Feed/community posts draw their photo
// with YTImageZoomNode inside a square Elements (Yoga) box and aspect-fill it, so
// anything that isn't 1:1 gets cropped. Once the image is known, the square box (the
// node itself and any wrapper with the very same frame) gets the image's own ratio
// and the cell is relaid out. Multi-image carousels keep their squares: their items
// share one row height, so mixed ratios would only leave gaps.
typedef struct { NSInteger unit; CGFloat value; } YMASDimension; // ASDimension: 0 auto, 1 points, 2 fraction

@interface ASLayoutElementStyleYoga (YouModAspect)
- (CGFloat)aspectRatio;
- (void)setAspectRatio:(CGFloat)ratio;
- (YMASDimension)height;
- (void)setHeight:(YMASDimension)height;
@end

@interface YTImageZoomNode : ASDisplayNode
- (UIImage *)image;
@end

static const void *kYMPostAspectKey = &kYMPostAspectKey;

static BOOL YMPostImageInCarousel(ASDisplayNode *node) {
    static Class scrollClass, collectionClass, horizontalScrollClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scrollClass = NSClassFromString(@"ASScrollNode");
        collectionClass = NSClassFromString(@"ELMCollectionNode");
        horizontalScrollClass = NSClassFromString(@"ELMScrollableContainerNode2");
    });
    NSInteger depth = 0;
    for (ASDisplayNode *n = node.yogaParent; n && depth < 12; n = n.yogaParent, depth++) {
        if ((scrollClass && [n isKindOfClass:scrollClass]) || (collectionClass && [n isKindOfClass:collectionClass]) || (horizontalScrollClass && [n isKindOfClass:horizontalScrollClass])) return YES;
    }
    return NO;
}

static void YMApplyPostImageAspect(YTImageZoomNode *node) {
    if (!IS_ENABLED(PostOriginalAspect)) return;
    UIImage *image = node.image;
    if (!image || image.size.width < 1 || image.size.height < 1) return;
    CGSize box = node.calculatedSize;
    if (box.width < 1 || box.height < 1) return; // not laid out yet; calculatedLayoutDidChange comes back
    // Very tall or very wide images are kept within 1:2 and 3:1 so one post can't fill
    // several screens.
    CGFloat ratio = MIN(MAX(image.size.width / image.size.height, 0.5), 3.0);
    NSNumber *applied = objc_getAssociatedObject(node, kYMPostAspectKey);
    if (applied && fabs(applied.doubleValue - ratio) < 0.01) return;
    // Only the square crop is changed; anything else is the template's own design.
    if (fabs(box.width - box.height) > 1.0) return;
    if (fabs(ratio - 1.0) < 0.02) return;
    if (YMPostImageInCarousel(node)) return;

    ASDisplayNode *top = nil;
    NSInteger depth = 0;
    for (ASDisplayNode *n = node; n && depth < 4; n = n.yogaParent, depth++) {
        CGSize size = n.calculatedSize;
        if (fabs(size.width - box.width) > 1.0 || fabs(size.height - box.height) > 1.0) break;
        ASLayoutElementStyleYoga *style = n.style;
        if (![style respondsToSelector:@selector(setAspectRatio:)]) break;
        YMASDimension height = style.height;
        if (height.unit == 1) style.height = (YMASDimension){0, 0}; // fixed square height -> auto
        style.aspectRatio = ratio; // Yoga: width / height
        top = n;
    }
    if (!top) return;
    objc_setAssociatedObject(node, kYMPostAspectKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [node setNeedsLayout];
    [top setNeedsLayout];
}

static void YMSchedulePostImageAspect(YTImageZoomNode *node) {
    if (!IS_ENABLED(PostOriginalAspect)) return;
    __weak YTImageZoomNode *weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTImageZoomNode *strongNode = weakNode;
        if (strongNode) YMApplyPostImageAspect(strongNode);
    });
}

%hook YTImageZoomNode
- (void)setImage:(UIImage *)image {
    %orig;
    if (image) YMSchedulePostImageAspect(self);
}
- (void)calculatedLayoutDidChange {
    %orig;
    if (self.image) YMSchedulePostImageAspect(self);
}
// Elements re-applies the template's style when the cell is reused/updated.
- (void)controllerDidApplyProperties {
    %orig;
    objc_setAssociatedObject(self, kYMPostAspectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (self.image) YMSchedulePostImageAspect(self);
}
%end
