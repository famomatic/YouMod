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
// Post images at their original aspect ratio. Posts draw their photo with an
// Elements image node (ELMImageNode, or YTImageZoomNode where pinch-zoom is on) in a
// square Yoga box and aspect-fill it, so anything that isn't 1:1 gets cropped. Once
// the image is known, the square box (the node itself and any wrapper with the very
// same frame) gets the image's own ratio and the cell is relaid out. Multi-image
// carousels keep their squares: their items share one row height, so mixed ratios
// would only leave gaps.
typedef struct { NSInteger unit; CGFloat value; } YMASDimension; // ASDimension: 0 auto, 1 points, 2 fraction

@interface ASLayoutElementStyleYoga (YouModAspect)
- (CGFloat)aspectRatio;
- (void)setAspectRatio:(CGFloat)ratio;
- (YMASDimension)height;
- (void)setHeight:(YMASDimension)height;
@end

@interface ASDisplayNode (YouModAspect)
- (ASDisplayNode *)supernode;
- (UIImage *)image;
@end

static const void *kYMPostAspectKey = &kYMPostAspectKey;
static const CGFloat kYMPostImageMinWidth = 150; // skips avatars, icons, badges

static ASDisplayNode *YMNodeParent(ASDisplayNode *node) {
    ASDisplayNode *parent = node.yogaParent;
    if (!parent && [node respondsToSelector:@selector(supernode)]) parent = node.supernode;
    return parent;
}

static BOOL YMNodeIsPostRoot(ASDisplayNode *node) {
    NSString *identifier = node.accessibilityIdentifier;
    if (identifier.length) {
        // id.ui.backstage.original_post, images_post_root_slim.eml, post_base_wrapper_slim.eml, ...
        NSString *lower = identifier.lowercaseString;
        if ([lower containsString:@"backstage"] || [lower containsString:@"post"]) return YES;
    }
    return NO;
}

// YES when `node` sits in a post and not inside a horizontally scrolling carousel.
static BOOL YMPostImageEligible(ASDisplayNode *node) {
    static Class scrollClass, collectionClass, scrollContainerClass, cellClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scrollClass = NSClassFromString(@"ASScrollNode");
        collectionClass = NSClassFromString(@"ELMCollectionNode");
        scrollContainerClass = NSClassFromString(@"ELMScrollableContainerNode2");
        cellClass = NSClassFromString(@"ASCellNode");
    });
    NSInteger depth = 0;
    for (ASDisplayNode *n = YMNodeParent(node); n && depth < 40; n = YMNodeParent(n), depth++) {
        if (YMNodeIsPostRoot(n)) return YES;
        if ((scrollClass && [n isKindOfClass:scrollClass]) || (collectionClass && [n isKindOfClass:collectionClass]) || (scrollContainerClass && [n isKindOfClass:scrollContainerClass])) return NO;
        if (cellClass && [n isKindOfClass:cellClass]) return NO; // reached the feed cell without a post root
    }
    return NO;
}

static void YMApplyPostImageAspect(ASDisplayNode *node) {
    if (!IS_ENABLED(PostOriginalAspect)) return;
    UIImage *image = [node respondsToSelector:@selector(image)] ? node.image : nil;
    if (!image || image.size.width < 1 || image.size.height < 1) return;
    CGSize box = node.calculatedSize;
    if (box.width < kYMPostImageMinWidth || box.height < 1) return; // not laid out yet; calculatedLayoutDidChange comes back
    // Very tall or very wide images are kept within 1:2 and 3:1 so one post can't fill
    // several screens.
    CGFloat ratio = MIN(MAX(image.size.width / image.size.height, 0.5), 3.0);
    NSNumber *applied = objc_getAssociatedObject(node, kYMPostAspectKey);
    if (applied && fabs(applied.doubleValue - ratio) < 0.01) return;
    // Only the square crop is changed; anything else is the template's own design.
    if (fabs(box.width - box.height) > 1.0) return;
    if (fabs(ratio - 1.0) < 0.02) return;
    if (!YMPostImageEligible(node)) return;

    ASDisplayNode *top = nil;
    NSInteger depth = 0;
    for (ASDisplayNode *n = node; n && depth < 4; n = YMNodeParent(n), depth++) {
        CGSize size = n.calculatedSize;
        if (fabs(size.width - box.width) > 1.0 || fabs(size.height - box.height) > 1.0) break;
        ASLayoutElementStyleYoga *style = n.style;
        if (![style respondsToSelector:@selector(setAspectRatio:)]) break;
        if ([style respondsToSelector:@selector(height)] && style.height.unit == 1) style.height = (YMASDimension){0, 0}; // fixed square height -> auto
        style.aspectRatio = ratio; // Yoga: width / height
        top = n;
    }
    if (!top) return;
    objc_setAssociatedObject(node, kYMPostAspectKey, @(ratio), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (ASDisplayNode *n = node; n; n = YMNodeParent(n)) {
        [n setNeedsLayout];
        if (n == top) break;
    }
}

static void YMSchedulePostImageAspect(ASDisplayNode *node) {
    if (!IS_ENABLED(PostOriginalAspect)) return;
    __weak ASDisplayNode *weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (strongNode) YMApplyPostImageAspect(strongNode);
    });
}

%hook ELMImageNode
- (void)setImage:(UIImage *)image {
    %orig;
    if (image) YMSchedulePostImageAspect((ASDisplayNode *)self);
}
- (void)calculatedLayoutDidChange {
    %orig;
    YMSchedulePostImageAspect((ASDisplayNode *)self);
}
// Elements re-applies the template's style when the cell is updated.
- (void)controllerDidApplyProperties {
    %orig;
    objc_setAssociatedObject(self, kYMPostAspectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YMSchedulePostImageAspect((ASDisplayNode *)self);
}
%end

%hook YTImageZoomNode
- (void)setImage:(UIImage *)image {
    %orig;
    if (image) YMSchedulePostImageAspect((ASDisplayNode *)self);
}
- (void)calculatedLayoutDidChange {
    %orig;
    YMSchedulePostImageAspect((ASDisplayNode *)self);
}
- (void)controllerDidApplyProperties {
    %orig;
    objc_setAssociatedObject(self, kYMPostAspectKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YMSchedulePostImageAspect((ASDisplayNode *)self);
}
%end
