#import "Headers.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MPVolumeView.h>

// Radio Mode: audio-only playback, like YouTube Music's now-playing screen. Entered
// via a button placed under the like/dislike/share/download row (the real "Listen
// on YouTube Music" button's spot for official music videos). Hides the video behind
// an opaque cover with title/author and repeat/shuffle/volume controls, and keeps
// Picture in Picture from popping up while active.
//
// Nothing here is reimplemented from scratch: repeat reuses the existing KeepLoopKey
// toggle (YouModLoopButton, already wired up in OverlayButtons.x), and shuffle forwards
// a tap to YouTube's own real shuffle button in the playlist/up-next panel
// (id.playlist_panel.shuffle.button) rather than reimplementing YTQueueShuffleController,
// which is undocumented (no header exists for it anywhere) and too large a reverse-
// engineering job for what this needs.

extern YTPlayerViewController *YouModDownloadGetCurrentPlayer(void);
extern NSString *YouModTitleForPlayer(YTPlayerViewController *player);
extern NSString *YouModAuthorForPlayer(YTPlayerViewController *player);

@interface YTPlayerViewController (YouModRadio)
- (void)YouModLoopButton;
@end

static BOOL gYMRadioModeActive = NO;

// So OverlayButtons.x can hide its own overlay buttons/stepper while Radio Mode
// covers the video - they'd otherwise float uselessly on top of the cover.
BOOL YouModRadioModeActive(void) {
    return gYMRadioModeActive;
}

static NSInteger const YMRadioEntryButtonTag = 9920;
static NSInteger const YMRadioCoverTag = 9921;
static NSInteger const YMRadioTitleTag = 9923;
static NSInteger const YMRadioAuthorTag = 9924;
static NSInteger const YMRadioShuffleTag = 9925;
static NSInteger const YMRadioRepeatTag = 9926;
static NSInteger const YMRadioVolumeTag = 9927;

#pragma mark - Finding real native views by accessibility identifier

static UIView *YMFindDescendantWithIdentifier(UIView *root, NSString *identifier) {
    for (UIView *sub in root.subviews) {
        if ([sub.accessibilityIdentifier isEqualToString:identifier]) return sub;
        UIView *found = YMFindDescendantWithIdentifier(sub, identifier);
        if (found) return found;
    }
    return nil;
}

static UIWindow *YMKeyWindowForSearch(void) {
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) return window;
    }
    return [UIApplication sharedApplication].windows.firstObject;
}

static UIControl *YMNativeShuffleButton(void) {
    return (UIControl *)YMFindDescendantWithIdentifier(YMKeyWindowForSearch(), @"id.playlist_panel.shuffle.button");
}

#pragma mark - Toggling Radio Mode

static void YMToggleRadioMode(void) {
    gYMRadioModeActive = !gYMRadioModeActive;
    YTPlayerViewController *player = YouModDownloadGetCurrentPlayer();
    YTMainAppVideoPlayerOverlayViewController *ovcon = [player activeVideoPlayerOverlay];
    YTMainAppVideoPlayerOverlayView *ovview = [ovcon videoPlayerOverlayView];
    YTMainAppControlsOverlayView *conview = [ovview controlsOverlayView];
    [conview setNeedsLayout];
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
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if (!IS_ENABLED(RadioMode)) return;
    if ([self.accessibilityIdentifier isEqualToString:@"id.video.non_scrollable_action_bar"]) {
        YMLayoutRadioEntryButton(self);
    }
}
%end

#pragma mark - The cover: hides the video, shows title/author + repeat/shuffle/volume

static void YMUpdateRadioRepeatIcon(UIButton *button) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
    NSString *symbol = IS_ENABLED(KeepLoopKey) ? @"repeat.1" : @"repeat";
    [button setImage:[[UIImage systemImageNamed:symbol withConfiguration:config] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    button.tintColor = IS_ENABLED(KeepLoopKey) ? [UIColor systemRedColor] : [UIColor whiteColor];
}

static void YMLayoutRadioCover(YTMainAppControlsOverlayView *overlay) {
    UIView *cover = [overlay viewWithTag:YMRadioCoverTag];
    if (!gYMRadioModeActive || !IS_ENABLED(RadioMode)) {
        cover.hidden = YES;
        return;
    }

    if (!cover) {
        cover = [[UIView alloc] init];
        cover.tag = YMRadioCoverTag;
        cover.backgroundColor = [UIColor blackColor];

        UIImageSymbolConfiguration *bgConfig = [UIImageSymbolConfiguration configurationWithPointSize:48 weight:UIImageSymbolWeightLight];
        UIImageView *icon = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"headphones" withConfiguration:bgConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        icon.tintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        icon.contentMode = UIViewContentModeCenter;
        icon.translatesAutoresizingMaskIntoConstraints = YES;
        icon.tag = 'icon';
        [cover addSubview:icon];

        YTLabel *title = [%c(YTLabel) new];
        title.tag = YMRadioTitleTag;
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        title.textAlignment = NSTextAlignmentCenter;
        title.numberOfLines = 2;
        [cover addSubview:title];

        YTLabel *author = [%c(YTLabel) new];
        author.tag = YMRadioAuthorTag;
        author.textColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        author.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        author.textAlignment = NSTextAlignmentCenter;
        [cover addSubview:author];

        UIImageSymbolConfiguration *btnConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];

        UIButton *shuffle = [UIButton buttonWithType:UIButtonTypeSystem];
        shuffle.tag = YMRadioShuffleTag;
        [shuffle setImage:[[UIImage systemImageNamed:@"shuffle" withConfiguration:btnConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
        shuffle.tintColor = [UIColor whiteColor];
        [shuffle addAction:[UIAction actionWithHandler:^(UIAction *action) {
            // Forwards to the real native shuffle button rather than reimplementing it.
            [YMNativeShuffleButton() sendActionsForControlEvents:UIControlEventTouchUpInside];
        }] forControlEvents:UIControlEventTouchUpInside];
        [cover addSubview:shuffle];

        UIButton *repeatBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        repeatBtn.tag = YMRadioRepeatTag;
        [cover addSubview:repeatBtn];
        [repeatBtn addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [YouModDownloadGetCurrentPlayer() YouModLoopButton];
            YMUpdateRadioRepeatIcon(repeatBtn);
        }] forControlEvents:UIControlEventTouchUpInside];

        MPVolumeView *volume = [[MPVolumeView alloc] init];
        volume.tag = YMRadioVolumeTag;
        [cover addSubview:volume];

        [overlay insertSubview:cover atIndex:0];
    }

    cover.hidden = NO;
    cover.frame = overlay.bounds;
    CGFloat width = cover.bounds.size.width;
    CGFloat height = cover.bounds.size.height;

    UIImageView *icon = [cover viewWithTag:'icon'];
    icon.frame = cover.bounds;

    YTPlayerViewController *player = YouModDownloadGetCurrentPlayer();
    YTLabel *title = (YTLabel *)[cover viewWithTag:YMRadioTitleTag];
    title.text = YouModTitleForPlayer(player) ?: @"";
    YTLabel *author = (YTLabel *)[cover viewWithTag:YMRadioAuthorTag];
    author.text = YouModAuthorForPlayer(player) ?: @"";
    title.frame = CGRectMake(20, height / 2.0 - 30, width - 40, 40);
    author.frame = CGRectMake(20, CGRectGetMaxY(title.frame) + 4, width - 40, 18);

    UIButton *shuffle = (UIButton *)[cover viewWithTag:YMRadioShuffleTag];
    UIButton *repeatBtn = (UIButton *)[cover viewWithTag:YMRadioRepeatTag];
    MPVolumeView *volume = (MPVolumeView *)[cover viewWithTag:YMRadioVolumeTag];
    YMUpdateRadioRepeatIcon(repeatBtn);

    // Shuffle only makes sense (and only has a real native button to forward to)
    // when this video is playing as part of a playlist/queue.
    BOOL hasPlaylist = (YMNativeShuffleButton() != nil);
    shuffle.hidden = !hasPlaylist;

    CGFloat controlsY = height - 70;
    CGFloat centerX = width / 2.0;
    repeatBtn.frame = CGRectMake(centerX - 18, controlsY, 36, 36);
    if (hasPlaylist) {
        shuffle.frame = CGRectMake(centerX - 90, controlsY, 36, 36);
    }
    volume.frame = CGRectMake(20, height - 28, width - 40, 20);
}

%hook YTMainAppControlsOverlayView
- (void)layoutSubviews {
    %orig;
    YMLayoutRadioCover(self);
}
%end

#pragma mark - Keeping Picture in Picture from popping up while Radio Mode is active

%hook AVPictureInPictureController
- (BOOL)canStartPictureInPictureAutomaticallyFromInline {
    if (gYMRadioModeActive) return NO;
    return %orig;
}
%end
