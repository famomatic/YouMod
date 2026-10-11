// NotchAvoidance.x
// Ported from DontEatMyContent (https://github.com/therealFoxster/DontEatMyContent) by
// therealFoxster. Keeps the notch/Dynamic Island from cutting into wide (~21:9+)
// fullscreen video by letting the rendering view grow slightly past the safe area
// instead of being letterboxed inside it.
//
// Two classes the original hooked no longer exist in current YouTube builds
// (confirmed against 21.40.5's Objective-C class list):
//   - YTVideoZoomOverlayView: legacy fallback for when pinch-to-zoom is unavailable.
//     The pinch-to-zoom-available sibling (YTVideoFreeZoomOverlayView, hooked below)
//     is confirmed alive and is the one that actually fires, so this fallback is
//     dropped rather than ported.
//   - YTMainAppEngagementPanelViewController: the "panel about to show" notification.
//     Its logic is folded into the still-alive YTEngagementPanelContainerViewController
//     below (-viewWillAppear:), using isWatchLandscapeEngagementPanel in place of the
//     now-dead isLandscapeEngagementPanel (the dismiss-side hook in this same class
//     already had to make that same substitution).
#import "Headers.h"
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTPlayerView.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTEngagementPanelContainerViewController.h>

#define NOTCH_AVOID_THRESHOLD 1.97
#define NOTCH_AVOID_CONSTANT 21.5

static CGFloat notchAvoidAspectRatio = 16.0 / 9.0;
static BOOL notchAvoidIsZoomedToFill = NO;
static BOOL notchAvoidIsEngagementPanelVisible = NO;
static BOOL notchAvoidIsEngagementPanelViewControllerRemoved = NO;
static UIView *notchAvoidRenderingView;
static NSLayoutConstraint *notchAvoidWidthConstraint, *notchAvoidHeightConstraint, *notchAvoidCenterXConstraint, *notchAvoidCenterYConstraint;

static void NotchAvoid_centerRenderingView() {
    notchAvoidCenterXConstraint.active = YES;
    notchAvoidCenterYConstraint.active = YES;
}

static void NotchAvoid_deactivateConstraints() {
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    notchAvoidRenderingView.translatesAutoresizingMaskIntoConstraints = YES;
}

static void NotchAvoid_activateConstraints() {
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    if (notchAvoidAspectRatio < NOTCH_AVOID_THRESHOLD && !IS_ENABLED(AvoidNotchForAllVideos)) {
        NotchAvoid_deactivateConstraints();
        return;
    }
    NotchAvoid_centerRenderingView();
    notchAvoidRenderingView.translatesAutoresizingMaskIntoConstraints = NO;
    notchAvoidWidthConstraint.active = YES;
    notchAvoidHeightConstraint.active = YES;
}

// Download.x already hooks YTPlayerViewController's -viewDidAppear:, so this runs
// as a plain function called from that existing override instead of a second
// conflicting %hook block on the same selector.
void NotchAvoid_setupForPlayerViewController(YTPlayerViewController *self) {
    YTPlayerView *playerView = [self playerView];
    UIView *renderingViewContainer = [playerView valueForKey:@"_renderingViewContainer"];
    notchAvoidRenderingView = [playerView renderingView];
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    notchAvoidWidthConstraint = [notchAvoidRenderingView.widthAnchor constraintEqualToAnchor:renderingViewContainer.safeAreaLayoutGuide.widthAnchor constant:NOTCH_AVOID_CONSTANT];
    notchAvoidHeightConstraint = [notchAvoidRenderingView.heightAnchor constraintEqualToAnchor:renderingViewContainer.safeAreaLayoutGuide.heightAnchor constant:NOTCH_AVOID_CONSTANT];
    notchAvoidCenterXConstraint = [notchAvoidRenderingView.centerXAnchor constraintEqualToAnchor:renderingViewContainer.centerXAnchor];
    notchAvoidCenterYConstraint = [notchAvoidRenderingView.centerYAnchor constraintEqualToAnchor:renderingViewContainer.centerYAnchor];
    YTMainAppVideoPlayerOverlayViewController *activeVideoPlayerOverlay = [self activeVideoPlayerOverlay];
    if ([activeVideoPlayerOverlay isKindOfClass:%c(YTMainAppVideoPlayerOverlayViewController)] &&
        [activeVideoPlayerOverlay isFullscreen] && !notchAvoidIsZoomedToFill && !notchAvoidIsEngagementPanelVisible)
        NotchAvoid_activateConstraints();
}

// SponsorBlock.x already hooks YTPlayerViewController's
// -playbackController:didActivateVideo:withPlaybackData:, so this runs as a plain
// function called from that existing override instead of a second conflicting
// %hook block on the same selector.
void NotchAvoid_onDidActivateVideo(YTPlayerViewController *self) {
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    if ([self.parentViewController isKindOfClass:NSClassFromString(@"YTInlineMutedPlaybackWatchViewController")]) return;
    notchAvoidIsEngagementPanelVisible = NO;
    notchAvoidIsEngagementPanelViewControllerRemoved = NO;
    if ([[self activeVideoPlayerOverlay] isFullscreen])
        NotchAvoid_activateConstraints();
    else if (![self isCurrentVideoVertical] && ((YTPlayerView *)[self playerView]).userInteractionEnabled)
        NotchAvoid_deactivateConstraints();
}

%hook YTPlayerViewController

- (void)setPlayerViewLayout:(int)layout {
    %orig;
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    if (![[self activeVideoPlayerOverlay] isKindOfClass:%c(YTMainAppVideoPlayerOverlayViewController)])
        return;
    switch (layout) {
    case 2:
        NotchAvoid_deactivateConstraints();
        break;
    case 3: // Fullscreen
        if (!notchAvoidIsZoomedToFill && !notchAvoidIsEngagementPanelVisible)
            NotchAvoid_activateConstraints();
        break;
    default:
        break;
    }
}

%end

%hook YTPlayerView
- (void)setAspectRatio:(CGFloat)aspectRatio {
    %orig;
    notchAvoidAspectRatio = aspectRatio;
}
%end

%hook YTVideoFreeZoomOverlayView
- (void)didRecognizePinch:(UIPinchGestureRecognizer *)pinchGestureRecognizer {
    if (IS_ENABLED(AvoidNotchInFullscreen)) NotchAvoid_deactivateConstraints();
    %orig;
}
- (void)showLabelForSnapState:(NSInteger)snapState {
    if (IS_ENABLED(AvoidNotchInFullscreen)) {
        if (snapState == 0) { // Original
            notchAvoidIsZoomedToFill = NO;
            NotchAvoid_activateConstraints();
        } else if (snapState == 1) { // Zoomed to fill
            notchAvoidIsZoomedToFill = YES;
        }
    }
    %orig;
}
%end

// YTWatchMiniBarViewController is gone from current YouTube builds (the dismiss
// method this once relied on - dismissMiniBarWithVelocity:gestureType: - has been
// replaced by maybeDismissMiniBarWithVelocity:gestureType:shouldTranslatePosition:
// on what looks like YTPlaylistMiniBarViewController, unconfirmed on-device). Kept
// as a harmless no-op hook until the real successor class is confirmed; losing it
// only means isZoomedToFill doesn't get reset when the mini bar is dismissed.
%hook YTWatchMiniBarViewController
- (void)dismissMiniBarWithVelocity:(CGFloat)velocity gestureType:(int)gestureType {
    %orig;
    if (IS_ENABLED(AvoidNotchInFullscreen)) notchAvoidIsZoomedToFill = NO;
}
- (void)dismissMiniBarWithVelocity:(CGFloat)velocity gestureType:(int)gestureType skipShouldDismissCheck:(BOOL)skipShouldDismissCheck {
    %orig;
    if (IS_ENABLED(AvoidNotchInFullscreen)) notchAvoidIsZoomedToFill = NO;
}
%end

%hook YTEngagementPanelContainerViewController

// Panel about to show. YTMainAppEngagementPanelViewController (the class this used
// to live on) no longer exists; YTEngagementPanelContainerViewController is the
// still-alive sibling that already handles the dismiss side below.
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!IS_ENABLED(AvoidNotchInFullscreen)) return;
    if ([self respondsToSelector:@selector(isPeekingSupported)] && [self isPeekingSupported]) {
        // Shorts (only Shorts support peeking)
    } else {
        notchAvoidIsEngagementPanelVisible = YES;
        BOOL isLandscapePanel = [self respondsToSelector:@selector(isWatchLandscapeEngagementPanel)]
            ? self.watchLandscapeEngagementPanel
            : [self respondsToSelector:@selector(isLandscapeEngagementPanel)] && self.landscapeEngagementPanel;
        if (isLandscapePanel) NotchAvoid_deactivateConstraints();
    }
}

// Panel about to dismiss
- (void)notifyEngagementPanelContainerControllerWillHideFinalPanel {
    if (IS_ENABLED(AvoidNotchInFullscreen) && ![self isPeekingSupported] && !notchAvoidIsEngagementPanelViewControllerRemoved) {
        notchAvoidIsEngagementPanelVisible = NO;
        BOOL isLandscapePanel = [self respondsToSelector:@selector(isWatchLandscapeEngagementPanel)]
            ? self.watchLandscapeEngagementPanel
            : self.landscapeEngagementPanel;
        if (isLandscapePanel && !notchAvoidIsZoomedToFill) NotchAvoid_activateConstraints();
    }
    %orig;
}

%end
