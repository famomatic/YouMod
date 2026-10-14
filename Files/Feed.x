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
static const void *kYMPostUncroppedKey = &kYMPostUncroppedKey;

// Post photos are served from YouTube's image server (yt3.ggpht.com /
// *.googleusercontent.com) with options after "=" that ask it for a square crop:
// "=s1080-c-fcrop64=1,00000000ffffffff-rw-nd-v1" ("c" = crop to an s×s square). The
// app therefore only ever receives a square picture. Dropping the crop/size options
// and asking for the long side instead returns the whole photo. Avatars and banners
// (marked by "k", "c0x...", "no", "rj") keep their URL.
static NSURL *YMUncroppedPostImageURL(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    if (!([host hasSuffix:@"ggpht.com"] || [host hasSuffix:@"googleusercontent.com"])) return nil;
    NSString *string = url.absoluteString;
    // The options start at the first "=" of the last path segment ("fcrop64=" has one too).
    NSRange slash = [string rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return nil;
    NSRange eq = [string rangeOfString:@"=" options:0 range:NSMakeRange(slash.location, string.length - slash.location)];
    if (eq.location == NSNotFound) return nil;
    NSString *base = [string substringToIndex:eq.location];
    if ([base containsString:@"?"]) return nil;
    NSArray<NSString *> *options = [[string substringFromIndex:eq.location + 1] componentsSeparatedByString:@"-"];
    BOOL crop = NO, framed = NO;
    NSInteger size = 0;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *option in options) {
        if ([option isEqualToString:@"c"] || [option isEqualToString:@"p"]) { crop = YES; continue; }
        if ([option hasPrefix:@"fcrop64"]) { framed = YES; continue; }
        if ([option isEqualToString:@"k"] || [option hasPrefix:@"c0x"] || [option isEqualToString:@"no"] || [option isEqualToString:@"rj"]) return nil;
        if (option.length > 1 && ([option hasPrefix:@"s"] || [option hasPrefix:@"w"] || [option hasPrefix:@"h"])) {
            NSString *digits = [option substringFromIndex:1];
            if ([digits rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound) {
                size = MAX(size, digits.integerValue);
                continue;
            }
        }
        [kept addObject:option];
    }
    // Post photos carry both the square crop and the fcrop64 frame; big enough to
    // be the photo itself, not a tiny preview.
    if (!crop || !framed || size < 300) return nil;
    [kept insertObject:[NSString stringWithFormat:@"s%ld", (long)MIN(MAX(size, 1080), 2048)] atIndex:0];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@=%@", base, [kept componentsJoinedByString:@"-"]]];
}

static NSURL *YMPostImageURLForNode(ASDisplayNode *node, NSURL *url) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = IS_ENABLED(PostOriginalAspect); });
    if (!enabled || !url) return url;
    NSURL *uncropped = YMUncroppedPostImageURL(url);
    if (!uncropped) return url;
    objc_setAssociatedObject(node, kYMPostUncroppedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return uncropped;
}
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
    BOOL uncropped = [objc_getAssociatedObject(node, kYMPostUncroppedKey) boolValue];
    for (ASDisplayNode *n = YMNodeParent(node); n && depth < 40; n = YMNodeParent(n), depth++) {
        if (YMNodeIsPostRoot(n)) return YES;
        if ((scrollClass && [n isKindOfClass:scrollClass]) || (collectionClass && [n isKindOfClass:collectionClass]) || (scrollContainerClass && [n isKindOfClass:scrollContainerClass])) return NO;
        if (cellClass && [n isKindOfClass:cellClass]) return uncropped; // reached the cell without a recognized post root
    }
    return uncropped;
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
    // If the template's layout doesn't take the new ratio, at least show the whole
    // photo inside the square instead of cropping it.
    __weak ASDisplayNode *weakNode = node;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (!strongNode) return;
        CGSize size = strongNode.calculatedSize;
        if (size.height > 0 && fabs(size.width / size.height - ratio) > 0.05 && [strongNode respondsToSelector:@selector(setContentMode:)])
            ((void (*)(id, SEL, UIViewContentMode))objc_msgSend)(strongNode, @selector(setContentMode:), UIViewContentModeScaleAspectFit);
    });
}

// Every image node in the app passes through here (thumbnails, avatars, icons...), so
// everything that can be decided on the spot is, and only a big square box holding a
// non-square image - the post photo case - is handed to the main queue.
static void YMSchedulePostImageAspect(ASDisplayNode *node) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = IS_ENABLED(PostOriginalAspect); });
    if (!enabled) return;
    if (objc_getAssociatedObject(node, kYMPostAspectKey)) return;
    CGSize box = node.calculatedSize;
    if (box.width < kYMPostImageMinWidth || fabs(box.width - box.height) > 1.0) return;
    UIImage *image = [node respondsToSelector:@selector(image)] ? node.image : nil;
    if (!image || image.size.height < 1 || fabs(image.size.width / image.size.height - 1.0) < 0.02) return;
    __weak ASDisplayNode *weakNode = node;
    dispatch_async(dispatch_get_main_queue(), ^{
        ASDisplayNode *strongNode = weakNode;
        if (strongNode) YMApplyPostImageAspect(strongNode);
    });
}

%hook ELMImageNode
- (id)downloadImageWithURL:(NSURL *)url shouldRetry:(BOOL)retry callbackQueue:(id)queue downloadProgress:(id)progress completion:(id)completion {
    return %orig(YMPostImageURLForNode((ASDisplayNode *)self, url), retry, queue, progress, completion);
}
- (void)cachedImageWithURL:(NSURL *)url callbackQueue:(id)queue completion:(id)completion {
    %orig(YMPostImageURLForNode((ASDisplayNode *)self, url), queue, completion);
}
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
- (id)downloadImageWithURL:(NSURL *)url shouldRetry:(BOOL)retry callbackQueue:(id)queue downloadProgress:(id)progress completion:(id)completion {
    return %orig(YMPostImageURLForNode((ASDisplayNode *)self, url), retry, queue, progress, completion);
}
- (void)cachedImageWithURL:(NSURL *)url callbackQueue:(id)queue completion:(id)completion {
    %orig(YMPostImageURLForNode((ASDisplayNode *)self, url), queue, completion);
}
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
