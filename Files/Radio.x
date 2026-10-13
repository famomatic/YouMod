#import "Headers.h"
#import <AVKit/AVKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Radio Mode: audio-only playback, like YouTube Music's now-playing screen. Entered
// via a button placed under the like/dislike/share/download row or the radio overlay
// button. Turns YouTube's video track off (only audio is fetched and decoded) and
// covers the video area with its artwork (YouTube's controls and YouMod's overlay
// buttons - loop included - stay usable on top) and keeps Picture in Picture from
// popping up while active.

extern YTPlayerViewController *YouModDownloadGetCurrentPlayer(void);
extern NSString *YouModTitleForPlayer(YTPlayerViewController *player);
extern NSString *YouModAuthorForPlayer(YTPlayerViewController *player);

@interface YTPlayerViewController (YouModRadio)
- (void)YouModLoopButton;
@end

static BOOL gYMRadioModeActive = NO;

BOOL YouModRadioModeActive(void) {
    return gYMRadioModeActive;
}

static NSInteger const YMRadioEntryButtonTag = 9920;
static NSInteger const YMRadioCoverTag = 9921;
static NSInteger const YMRadioTitleTag = 9923;
static NSInteger const YMRadioAuthorTag = 9924;

static UIWindow *YMKeyWindowForSearch(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}


#pragma mark - Toggling Radio Mode

extern NSURL *YouModThumbnailURLForPlayer(YTPlayerViewController *player);
static void YMLayoutRadioCover(YTPlayerView *playerView);
static void YMRadioApplyPiPPolicy(void);
static void YMRadioApplyAudioOnly(YTPlayerViewController *player);

static void YMToggleRadioMode(void) {
    gYMRadioModeActive = !gYMRadioModeActive;
    YTPlayerViewController *player = YouModDownloadGetCurrentPlayer();
    YTMainAppVideoPlayerOverlayViewController *ovcon = [player activeVideoPlayerOverlay];
    YTMainAppVideoPlayerOverlayView *ovview = [ovcon videoPlayerOverlayView];
    YTMainAppControlsOverlayView *conview = [ovview controlsOverlayView];
    [conview setNeedsLayout];
    YTPlayerView *playerView = (YTPlayerView *)player.playerView;
    if ([playerView isKindOfClass:%c(YTPlayerView)]) YMLayoutRadioCover(playerView);
    YMRadioApplyPiPPolicy();
    YMRadioApplyAudioOnly(player);
    // Keep the action-bar entry button's title in sync where that button exists.
    UIButton *entry = (UIButton *)[YMKeyWindowForSearch() viewWithTag:YMRadioEntryButtonTag];
    [entry setTitle:LOC(gYMRadioModeActive ? @"RADIO_MODE_EXIT" : @"RADIO_MODE_ENTER") forState:UIControlStateNormal];
}

#pragma mark - The entry button, placed under the action bar (like/share/download row)

static void YMLayoutRadioEntryButton(UIView *actionBar) {
    if (!IS_ENABLED(RadioMode)) {
        UIView *existing = [actionBar.superview viewWithTag:YMRadioEntryButtonTag];
        existing.hidden = YES;
        return;
    }
    UIView *superview = actionBar.superview;
    if (!superview) return;

    UIButton *button = (UIButton *)[superview viewWithTag:YMRadioEntryButtonTag];
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = YMRadioEntryButtonTag;
        button.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        button.layer.cornerRadius = 18;
        button.tintColor = [UIColor whiteColor];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium];
        [button setImage:[[UIImage systemImageNamed:@"headphones" withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, 0);
        [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
            YMToggleRadioMode();
        }] forControlEvents:UIControlEventTouchUpInside];
        [superview addSubview:button];
    }

    button.hidden = NO;
    [button setTitle:LOC(gYMRadioModeActive ? @"RADIO_MODE_EXIT" : @"RADIO_MODE_ENTER") forState:UIControlStateNormal];
    CGRect barFrame = actionBar.frame;
    button.frame = CGRectMake(16, CGRectGetMaxY(barFrame) + 8, superview.bounds.size.width - 32, 36);
    [superview bringSubviewToFront:button];
}

// didMoveToWindow only (no layoutSubviews override here): _ASDisplayView backs every
// Texture node in the whole app, so layoutSubviews on it fires on every single layout
// pass of every cell everywhere - on top of the other files that already hook
// didMoveToWindow on this same class, adding a layoutSubviews hook here measurably
// compounds the relayout cost of any large reflow (e.g. the whole watch-next feed
// reflowing on fullscreen exit). didMoveToWindow is enough in practice: YouTube's
// Texture cells get recreated rather than just resized across a change this big,
// which is also the only hook Download.x's similar gesture-injection relies on.
// The action bar container itself isn't necessarily an _ASDisplayView (or at least
// isn't reliably reachable as one directly), so - matching the walk-up pattern
// Player.x's existing YouModFilterVideoButtons already uses successfully - this
// triggers off a child button that's always present (the like button) and walks
// up .superview looking for the container's identifier, rather than assuming the
// container fires its own didMoveToWindow with a matching identifier.
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (![self.accessibilityIdentifier isEqualToString:@"id.video.like.button"]) return;
    if (!IS_ENABLED(RadioMode)) return;
    UIView *test = self.superview;
    while (test != nil) {
        if ([test.accessibilityIdentifier isEqualToString:@"id.video.non_scrollable_action_bar"]) {
            YMLayoutRadioEntryButton(test);
            return;
        }
        test = test.superview;
    }
}
%end


#pragma mark - Audio only: drop the video track while Radio Mode is on

// YouTube streams audio and video as separate tracks, so nothing needs remuxing:
// the HAM player item asks its video format constraint whether to play the video
// track at all (-[MLHAMPlayerItem updateVideoTrackDisabled] checks -disableTrack),
// and YouTube ships MLDisableTrackFormatConstraint for exactly that. While Radio
// Mode is on the active item gets that constraint, so only audio is fetched and
// decoded; the constraint YouTube had set (quality setting etc.) is remembered per
// item and put back when Radio Mode ends. Constraints YouTube sets in the meantime
// (quality changes) are remembered instead of applied.
static const void *YMRadioSavedConstraintKey = &YMRadioSavedConstraintKey;
static const void *YMRadioHasSavedConstraintKey = &YMRadioHasSavedConstraintKey;

static id YMRadioDisableTrackConstraint(void) {
    static id constraint;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"MLDisableTrackFormatConstraint");
        constraint = cls ? [cls new] : nil;
    });
    return constraint;
}

static BOOL YMRadioIsDisableConstraint(id constraint) {
    Class cls = NSClassFromString(@"MLDisableTrackFormatConstraint");
    return cls && [constraint isKindOfClass:cls];
}

static id YMRadioPlayerItem(YTPlayerViewController *player) {
    id video = [player respondsToSelector:@selector(activeVideo)] ? [player activeVideo] : nil;
    return [video respondsToSelector:@selector(playerItem)] ? [video playerItem] : nil;
}

// Sets the active item's constraint according to Radio Mode.
static void YMRadioApplyAudioOnly(YTPlayerViewController *player) {
    id item = YMRadioPlayerItem(player);
    if (!item || ![item respondsToSelector:@selector(videoFormatConstraint)] || ![item respondsToSelector:@selector(setVideoFormatConstraint:)]) return;
    id current = [item videoFormatConstraint];
    BOOL wantAudioOnly = gYMRadioModeActive && IS_ENABLED(RadioMode);
    if (wantAudioOnly) {
        if (YMRadioIsDisableConstraint(current) || !YMRadioDisableTrackConstraint()) return;
        objc_setAssociatedObject(item, YMRadioSavedConstraintKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, YMRadioHasSavedConstraintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item setVideoFormatConstraint:YMRadioDisableTrackConstraint()];
    } else if ([objc_getAssociatedObject(item, YMRadioHasSavedConstraintKey) boolValue]) {
        id saved = objc_getAssociatedObject(item, YMRadioSavedConstraintKey);
        objc_setAssociatedObject(item, YMRadioHasSavedConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, YMRadioSavedConstraintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item setVideoFormatConstraint:saved];
    }
}

// YouTube changing the constraint while Radio Mode holds the item (e.g. a quality
// change): remember it for later instead of re-enabling video.
%group YMRadioAudioOnly
%hook MLHAMPlayerItem
- (void)setVideoFormatConstraint:(id)constraint {
    if ([objc_getAssociatedObject(self, YMRadioHasSavedConstraintKey) boolValue] && !YMRadioIsDisableConstraint(constraint) && gYMRadioModeActive) {
        objc_setAssociatedObject(self, YMRadioSavedConstraintKey, constraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    %orig;
}
%end
%end

#pragma mark - The cover: artwork over the video, YouTube's controls stay on top

// The cover lives in YTPlayerView's rendering view container - above the video,
// below the player overlay - so YouTube's own controls (play/pause, seek bar, time,
// fullscreen) and YouMod's overlay buttons keep working over it, it stays up when
// the controls auto-hide, and it follows the video into the mini player. (It used to
// sit inside the controls overlay: it vanished with the controls, covered the seek
// bar, and its volume slider sat where the scrubber is.)
static NSCache<NSString *, UIImage *> *YMRadioArtworkCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 20; });
    return cache;
}

static UIView *YMRadioRenderingContainer(YTPlayerView *playerView) {
    Ivar ivar = class_getInstanceVariable(object_getClass(playerView), "_renderingViewContainer");
    UIView *container = ivar ? object_getIvar(playerView, ivar) : nil;
    return [container isKindOfClass:UIView.class] ? container : nil;
}

static void YMRadioLoadArtwork(UIView *cover, YTPlayerViewController *player) {
    NSString *videoID = player.currentVideoID;
    UIImageView *art = [cover viewWithTag:YMRadioTitleTag + 100];
    UIImageView *backdrop = [cover viewWithTag:YMRadioTitleTag + 101];
    if (!videoID.length || [art.accessibilityIdentifier isEqualToString:videoID]) return;
    art.accessibilityIdentifier = videoID;
    UIImage *cached = [YMRadioArtworkCache() objectForKey:videoID];
    art.image = cached;
    backdrop.image = cached;
    if (cached) return;
    NSURL *url = YouModThumbnailURLForPlayer(player);
    if (!url) return;
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data.length ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [YMRadioArtworkCache() setObject:image forKey:videoID];
            if (![art.accessibilityIdentifier isEqualToString:videoID]) return;
            art.image = image;
            backdrop.image = image;
        });
    }] resume];
}

static UIView *YMRadioCreateCover(void) {
    UIView *cover = [UIView new];
    cover.tag = YMRadioCoverTag;
    cover.backgroundColor = UIColor.blackColor;
    cover.clipsToBounds = YES;
    cover.userInteractionEnabled = NO; // taps go to YouTube's player as usual
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIImageView *backdrop = [UIImageView new];
    backdrop.tag = YMRadioTitleTag + 101;
    backdrop.contentMode = UIViewContentModeScaleAspectFill;
    backdrop.alpha = 0.55;
    [cover addSubview:backdrop];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.tag = YMRadioTitleTag + 102;
    [cover addSubview:blur];

    UIImageView *art = [UIImageView new];
    art.tag = YMRadioTitleTag + 100;
    art.contentMode = UIViewContentModeScaleAspectFill;
    art.clipsToBounds = YES;
    art.layer.cornerRadius = 10;
    art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [cover addSubview:art];

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
    UIImageView *badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"headphones" withConfiguration:config]];
    badge.tag = YMRadioTitleTag + 103;
    badge.tintColor = UIColor.whiteColor;
    badge.contentMode = UIViewContentModeCenter;
    badge.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    badge.layer.cornerRadius = 13;
    badge.clipsToBounds = YES;
    [cover addSubview:badge];

    UILabel *title = [UILabel new];
    title.tag = YMRadioTitleTag;
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 2;
    [cover addSubview:title];
    UILabel *author = [UILabel new];
    author.tag = YMRadioAuthorTag;
    author.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    author.font = [UIFont systemFontOfSize:14];
    author.textAlignment = NSTextAlignmentCenter;
    [cover addSubview:author];
    return cover;
}

static void YMLayoutRadioCover(YTPlayerView *playerView) {
    UIView *container = YMRadioRenderingContainer(playerView);
    if (!container) return;
    UIView *cover = [container viewWithTag:YMRadioCoverTag];
    YTPlayerViewController *player = YouModDownloadGetCurrentPlayer();
    BOOL active = gYMRadioModeActive && IS_ENABLED(RadioMode) && player && player.playerView == (id)playerView;
    if (!active) {
        [cover removeFromSuperview];
        return;
    }
    if (!cover) cover = YMRadioCreateCover();
    if (cover.superview != container || container.subviews.lastObject != cover) [container addSubview:cover];
    cover.frame = container.bounds;

    CGFloat width = cover.bounds.size.width, height = cover.bounds.size.height;
    [cover viewWithTag:YMRadioTitleTag + 101].frame = cover.bounds;
    [cover viewWithTag:YMRadioTitleTag + 102].frame = cover.bounds;

    // Titles only where there is room (full screen); inline the page shows them.
    BOOL roomy = height >= 300;
    UILabel *title = [cover viewWithTag:YMRadioTitleTag];
    UILabel *author = [cover viewWithTag:YMRadioAuthorTag];
    title.hidden = author.hidden = !roomy;
    CGFloat textHeight = roomy ? 70 : 0;
    CGFloat artHeight = MAX(MIN((height - textHeight) * 0.6, width * 0.6 * 9 / 16), 24);
    CGFloat artWidth = artHeight * 16 / 9;
    CGFloat artY = (height - artHeight - textHeight) / 2;
    UIView *art = [cover viewWithTag:YMRadioTitleTag + 100];
    art.frame = CGRectMake((width - artWidth) / 2, artY, artWidth, artHeight);
    [cover viewWithTag:YMRadioTitleTag + 103].frame = CGRectMake(CGRectGetMaxX(art.frame) - 32, CGRectGetMaxY(art.frame) - 32, 26, 26);
    if (roomy) {
        title.text = YouModTitleForPlayer(player) ?: @"";
        author.text = YouModAuthorForPlayer(player) ?: @"";
        title.frame = CGRectMake(24, CGRectGetMaxY(art.frame) + 14, width - 48, 44);
        author.frame = CGRectMake(24, CGRectGetMaxY(title.frame) + 2, width - 48, 18);
    }
    YMRadioLoadArtwork(cover, player);
}

// The next video in a queue keeps Radio Mode on; refresh the cover's artwork.
%hook YTPlayerViewController
- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    if (!gYMRadioModeActive) return;
    // A new video in the queue starts with YouTube's constraint; drop its video too.
    YMRadioApplyAudioOnly(self);
    UIView *cover = [YMRadioRenderingContainer((YTPlayerView *)self.playerView) viewWithTag:YMRadioCoverTag];
    UIView *art = [cover viewWithTag:YMRadioTitleTag + 100];
    if (cover && ![art.accessibilityIdentifier isEqualToString:self.currentVideoID]) [(UIView *)self.playerView setNeedsLayout];
}
%end

%hook YTPlayerView
- (void)layoutSubviews {
    %orig;
    if (gYMRadioModeActive || [YMRadioRenderingContainer(self) viewWithTag:YMRadioCoverTag]) YMLayoutRadioCover(self);
}
%end

#pragma mark - Keeping Picture in Picture from popping up while Radio Mode is active

// YouTube sets canStartPictureInPictureAutomaticallyFromInline on its controller
// (AVKit reads the stored value, so overriding the getter did nothing) and may also
// start PiP itself when the app goes to the background. While Radio Mode is on both
// are turned off; leaving it restores what YouTube asked for. YouMod's own
// Downloads player is left alone.
static NSHashTable<AVPictureInPictureController *> *YMRadioPiPControllers(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static const void *YMRadioPiPWantedKey = &YMRadioPiPWantedKey;

static BOOL YMRadioIsYouTubePiP(AVPictureInPictureController *controller) {
    id delegate = controller.delegate;
    return !(delegate && [NSStringFromClass([delegate class]) hasPrefix:@"YMLocal"]);
}

%hook AVPictureInPictureController
- (void)setCanStartPictureInPictureAutomaticallyFromInline:(BOOL)enabled {
    if (!YMRadioIsYouTubePiP(self)) { %orig; return; }
    [YMRadioPiPControllers() addObject:self];
    objc_setAssociatedObject(self, YMRadioPiPWantedKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(gYMRadioModeActive ? NO : enabled);
}
- (void)startPictureInPicture {
    if (gYMRadioModeActive && YMRadioIsYouTubePiP(self)) return;
    %orig;
}
%end

// YouTube's PiP chain is YTPlayerPIPController -> MLPIPControllerImpl -> AVKit, and
// YouPiP (bundled by the IPA workflow) adds its own way in. Radio Mode turns on
// YouTube's own switch (pictureInPictureForceDisabled) and refuses every start;
// as a last resort a PiP that starts anyway is closed at once. Separately, YouTube
// can start PiP for a paused or finished video when the app goes to the background
// (startPictureInPictureWithPaused:YES); that is only allowed right after the user
// asked for PiP.
static NSTimeInterval ymRadioManualPiPRequest = 0;

static BOOL YMRadioRecentManualPiP(void) {
    return NSDate.timeIntervalSinceReferenceDate - ymRadioManualPiPRequest < 2.0;
}

%hook YTPlayerPIPController
- (BOOL)isPictureInPictureForceDisabled { return gYMRadioModeActive || %orig; }
- (BOOL)isPictureInPicturePossible { return gYMRadioModeActive ? NO : %orig; }
- (BOOL)canEnablePictureInPicture { return gYMRadioModeActive ? NO : %orig; }
- (BOOL)isEligibleForPictureInPicture { return gYMRadioModeActive ? NO : %orig; }
- (void)maybeTogglePictureInPicture {
    if (gYMRadioModeActive) return;
    ymRadioManualPiPRequest = NSDate.timeIntervalSinceReferenceDate;
    %orig;
}
%end

%hook MLPIPControllerImpl
- (void)startPictureInPictureWithPaused:(BOOL)paused {
    if (gYMRadioModeActive) return;
    if (paused && !YMRadioRecentManualPiP()) return;
    %orig;
}
- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    %orig;
    BOOL paused = [(id)self respondsToSelector:@selector(pictureInPictureControllerIsPlaybackPaused:)] &&
                  ((BOOL (*)(id, SEL, id))objc_msgSend)(self, @selector(pictureInPictureControllerIsPlaybackPaused:), controller);
    if (gYMRadioModeActive || (paused && !YMRadioRecentManualPiP())) {
        dispatch_async(dispatch_get_main_queue(), ^{ [controller stopPictureInPicture]; });
    }
}
%end

// Re-sends what YouTube asked for; the setter hook above turns it into NO while
// Radio Mode is on.
static void YMRadioApplyPiPPolicy(void) {
    for (AVPictureInPictureController *controller in YMRadioPiPControllers().allObjects) {
        NSNumber *wanted = objc_getAssociatedObject(controller, YMRadioPiPWantedKey);
        if (@available(iOS 14.2, *)) controller.canStartPictureInPictureAutomaticallyFromInline = wanted.boolValue;
        if (gYMRadioModeActive && controller.isPictureInPictureActive) [controller stopPictureInPicture];
    }
}

#pragma mark - Player overlay button (the reliable way in)

// The action-bar entry button above depends on a server-delivered layout container
// that isn't always there, so Radio Mode is also a regular player overlay button
// (manageable in Manage overlay buttons like the others).
%ctor {
    YMRegisterDefaults();
    %init;
    if (NSClassFromString(@"MLHAMPlayerItem")) %init(YMRadioAudioOnly);
    YMOverlayButtonSpec *radio = [[YMOverlayButtonSpec alloc] init];
    radio.identifier = @"radio.video";
    radio.symbolName = @"headphones";
    radio.settingsSymbolName = @"headphones";
    radio.displayName = LOC(@"RADIO_MODE_HEADER");
    radio.tintColor = [UIColor whiteColor];
    radio.sortOrder = 850;
    radio.isVisible = ^BOOL(YTPlayerViewController *player) {
        return IS_ENABLED(RadioMode) && YMIsOverlayButtonEnabled(@"radio.video");
    };
    radio.tintProvider = ^UIColor *(YTPlayerViewController *player) {
        return gYMRadioModeActive ? UIColor.systemRedColor : UIColor.whiteColor;
    };
    radio.onTap = ^(YTPlayerViewController *player, YTQTMButton *button) {
        YMToggleRadioMode();
        button.tintColor = gYMRadioModeActive ? UIColor.systemRedColor : UIColor.whiteColor;
    };
    YMRegisterOverlayButton(radio);
}
