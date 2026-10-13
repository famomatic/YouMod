// Player for finished downloads (see LocalPlayer.h). Modeled on uYou's
// PlayerManager/PlayerVC: one AVPlayer shared by a full-screen watch page and a
// mini bar, with a queue (next/previous, repeat, shuffle) taken from the list the
// item was started from, and system now-playing integration.
#import "Headers.h"
#import "DownloadLibrary.h"
#import "DownloadQueue.h"
#import "LocalPlayer.h"
#import "FFmpegKit.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <VideoToolbox/VideoToolbox.h>

NSString *const YMLocalPlaybackItemDidChangeNotification = @"YMLocalPlaybackItemDidChangeNotification";
NSString *const YMLocalPlaybackStateDidChangeNotification = @"YMLocalPlaybackStateDidChangeNotification";

extern YTPlayerViewController *YouModDownloadGetCurrentPlayer(void);

static const CGFloat YMMiniBarHeight = 62;
static NSTimeInterval ymLastRemoteCommandTime = 0;
static BOOL ymPlayerPresented;

NSString *YMLocalFormatTime(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    long total = (long)floor(seconds);
    if (total >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

static UIImage *YMSymbol(NSString *name, CGFloat size, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    return [UIImage systemImageNamed:name withConfiguration:config];
}

#pragma mark - Playability

// Video codecs AVPlayer decodes. VP9 is decoded by YouTube's own player, not by
// AVFoundation, so VP9 (and AV1 without a hardware decoder) needs converting.
static BOOL YMVideoCodecIsPlayable(FourCharCode codec) {
    switch (codec) {
        case 'avc1': case 'avc3': case 'hvc1': case 'hev1': case 'mp4v': case 'dvh1': case 'dvhe':
            return YES;
        case 'av01':
            if (@available(iOS 17.0, *)) return VTIsHardwareDecodeSupported('av01');
            return NO;
        default:
            return NO;
    }
}

static BOOL YMAudioCodecIsPlayable(FourCharCode codec) {
    if (codec == 'opus') {
        if (@available(iOS 17.0, *)) return YES;
        return NO;
    }
    return codec != 'vorb';
}

// Returns nil when the file plays in AVPlayer, otherwise the codec/container that
// doesn't (for the conversion prompt).
static NSString *YMLocalUnsupportedFormat(NSURL *url) {
    static NSCache<NSString *, NSString *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = url.path;
    NSString *cached = [cache objectForKey:key];
    if (cached) return cached.length ? cached : nil;

    NSString *result = @"";
    NSString *extension = url.pathExtension.lowercaseString;
    if ([@[@"mkv", @"webm", @"ogg", @"opus"] containsObject:extension]) {
        result = extension.uppercaseString;
    } else {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (!asset.isPlayable) {
            result = extension.uppercaseString ?: @"?";
        } else {
            for (AVAssetTrack *track in asset.tracks) {
                for (id description in track.formatDescriptions) {
                    FourCharCode codec = CMFormatDescriptionGetMediaSubType((__bridge CMFormatDescriptionRef)description);
                    if ([track.mediaType isEqualToString:AVMediaTypeVideo] && !YMVideoCodecIsPlayable(codec)) {
                        result = codec == 'vp09' ? @"VP9" : (codec == 'av01' ? @"AV1" : @"video codec");
                    } else if ([track.mediaType isEqualToString:AVMediaTypeAudio] && !YMAudioCodecIsPlayable(codec)) {
                        result = codec == 'opus' ? @"Opus" : @"audio codec";
                    }
                }
            }
        }
    }
    [cache setObject:result forKey:key];
    return result.length ? result : nil;
}

#pragma mark - Playback engine

@interface YMLocalPlayback ()
@property (nonatomic, strong, readwrite) AVPlayer *player;
@property (nonatomic, strong, readwrite) YMDownloadItem *currentItem;
@property (nonatomic, copy) NSArray<YMDownloadItem *> *queue;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order; // play order (indices into queue)
@property (nonatomic, assign) NSUInteger position;               // index into order
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSMutableArray *commandTargets;
@property (nonatomic, strong) NSHashTable<AVPlayerLayer *> *layers;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *artwork;
@property (nonatomic, assign) BOOL inBackground;
@property (nonatomic, assign) NSTimeInterval lastSavedPosition;
@property (nonatomic, weak) AVPictureInPictureController *pictureInPicture;
@end

@implementation YMLocalPlayback

+ (instancetype)sharedPlayback {
    static YMLocalPlayback *playback;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ playback = [YMLocalPlayback new]; });
    return playback;
}

- (instancetype)init {
    if ((self = [super init])) {
        _player = [AVPlayer new];
        _player.allowsExternalPlayback = YES;
        _player.automaticallyWaitsToMinimizeStalling = NO;
        _rate = 1.0f;
        _layers = [NSHashTable weakObjectsHashTable];
        _artwork = [NSCache new];
        _commandTargets = [NSMutableArray array];
        [_player addObserver:self forKeyPath:@"timeControlStatus" options:0 context:NULL];

        __weak typeof(self) weakSelf = self;
        _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            [weakSelf periodicTick];
        }];

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(itemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [center addObserver:self selector:@selector(itemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
        [center addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
        [center addObserver:self selector:@selector(libraryChanged) name:YMDownloadLibraryDidChangeNotification object:nil];
    }
    return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateNowPlaying];
        [self postState];
    });
}

- (void)postState {
    [NSNotificationCenter.defaultCenter postNotificationName:YMLocalPlaybackStateDidChangeNotification object:self];
}

- (BOOL)isPlaying {
    return self.player.timeControlStatus != AVPlayerTimeControlStatusPaused;
}

- (NSTimeInterval)currentTime {
    NSTimeInterval time = CMTimeGetSeconds(self.player.currentTime);
    return isfinite(time) ? time : 0;
}

- (NSTimeInterval)duration {
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    if (isfinite(duration) && duration > 0) return duration;
    return self.currentItem.durationMs / 1000.0;
}

- (BOOL)hasNext {
    return self.position + 1 < self.order.count || (self.repeatMode == YMRepeatModeAll && self.order.count > 1);
}

#pragma mark Queue

- (void)playItems:(NSArray<YMDownloadItem *> *)items startAtIndex:(NSUInteger)index {
    if (index >= items.count) return;
    [self saveResumePosition];
    self.queue = items;
    self.order = [NSMutableArray array];
    for (NSUInteger i = 0; i < items.count; i++) [self.order addObject:@(i)];
    self.position = index;
    if (self.shuffle) [self shuffleOrderKeepingCurrent];
    [self loadCurrentAndPlay:YES];
}

- (void)shuffleOrderKeepingCurrent {
    NSNumber *current = self.order.count ? self.order[self.position] : nil;
    NSMutableArray *rest = [self.order mutableCopy];
    if (current) [rest removeObject:current];
    for (NSUInteger i = rest.count; i > 1; i--) [rest exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    if (current) [rest insertObject:current atIndex:0];
    self.order = rest;
    self.position = 0;
}

- (void)setShuffle:(BOOL)shuffle {
    if (_shuffle == shuffle) return;
    _shuffle = shuffle;
    if (!self.order.count) { [self postState]; return; }
    if (shuffle) {
        [self shuffleOrderKeepingCurrent];
    } else {
        NSNumber *current = self.order[self.position];
        NSMutableArray *ordered = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.queue.count; i++) [ordered addObject:@(i)];
        self.order = ordered;
        self.position = current.unsignedIntegerValue;
    }
    [self postState];
}

- (void)setRepeatMode:(YMRepeatMode)repeatMode {
    _repeatMode = repeatMode;
    [self postState];
}

- (void)setRate:(float)rate {
    _rate = rate;
    if (self.isPlaying) self.player.rate = rate;
    [self updateNowPlaying];
    [self postState];
}

- (void)loadCurrentAndPlay:(BOOL)play {
    // Skip files that can't play (a conversion was declined, or the file is gone).
    NSUInteger attempts = 0;
    YMDownloadItem *item = nil;
    while (attempts++ < self.order.count) {
        YMDownloadItem *candidate = self.queue[self.order[self.position].unsignedIntegerValue];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.fileURL.path] && !YMLocalUnsupportedFormat(candidate.fileURL)) {
            item = candidate;
            break;
        }
        if (self.position + 1 >= self.order.count) break;
        self.position++;
    }
    if (!item) { [self stop]; return; }

    self.currentItem = item;
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:item.fileURL];
    [self.player replaceCurrentItemWithPlayerItem:playerItem];
    NSTimeInterval resume = [[YMDownloadLibrary sharedLibrary] resumePositionForItem:item];
    NSTimeInterval duration = item.durationMs / 1000.0;
    if (resume > 5 && (duration <= 0 || resume < duration - 5)) {
        [self.player seekToTime:CMTimeMakeWithSeconds(resume, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    self.lastSavedPosition = resume;

    [self installRemoteCommands];
    [self updateNowPlaying];
    [NSNotificationCenter.defaultCenter postNotificationName:YMLocalPlaybackItemDidChangeNotification object:self];
    if (play) [self play];
}

- (void)next {
    if (!self.order.count) return;
    [self saveResumePosition];
    if (self.position + 1 < self.order.count) {
        self.position++;
    } else if (self.repeatMode == YMRepeatModeAll) {
        if (self.shuffle) [self shuffleOrderKeepingCurrent];
        self.position = 0;
    } else {
        return;
    }
    [self loadCurrentAndPlay:YES];
}

- (void)previous {
    if (!self.order.count) return;
    if (self.currentTime > 3 || self.position == 0) {
        [self seekToTime:0];
        return;
    }
    [self saveResumePosition];
    self.position--;
    [self loadCurrentAndPlay:YES];
}

#pragma mark Transport

- (void)play {
    if (!self.player.currentItem) return;
    YTPlayerViewController *youtube = YouModDownloadGetCurrentPlayer();
    if ([youtube respondsToSelector:@selector(pause)]) [youtube pause];
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    if (self.duration > 0 && self.currentTime >= self.duration - 0.5) [self.player seekToTime:kCMTimeZero];
    [self.player playImmediatelyAtRate:self.rate];
}

- (void)pause {
    [self.player pause];
    [self saveResumePosition];
}

- (void)togglePlayPause {
    if (self.isPlaying) [self pause];
    else [self play];
}

- (void)seekToTime:(NSTimeInterval)time {
    NSTimeInterval duration = self.duration;
    if (duration > 0) time = MIN(time, duration - 0.1);
    time = MAX(time, 0);
    __weak typeof(self) weakSelf = self;
    [self.player seekToTime:CMTimeMakeWithSeconds(time, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateNowPlaying]; [weakSelf postState]; });
    }];
}

- (void)seekBy:(NSTimeInterval)delta {
    [self seekToTime:self.currentTime + delta];
}

- (void)stop {
    [self saveResumePosition];
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
    self.currentItem = nil;
    self.queue = nil;
    self.order = nil;
    self.position = 0;
    [self removeRemoteCommands];
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:YMLocalPlaybackItemDidChangeNotification object:self];
    [self postState];
}

- (void)itemDidPlayToEnd:(NSNotification *)note {
    if (note.object != self.player.currentItem) return;
    [[YMDownloadLibrary sharedLibrary] setResumePosition:0 forItem:self.currentItem];
    self.lastSavedPosition = 0;
    if (self.repeatMode == YMRepeatModeOne) {
        [self.player seekToTime:kCMTimeZero];
        [self.player playImmediatelyAtRate:self.rate];
    } else if (self.hasNext) {
        [self next];
    } else {
        [self postState];
    }
}

- (void)itemFailed:(NSNotification *)note {
    if (note.object != self.player.currentItem) return;
    YMDownloadShowToast(LOC(@"PLAYBACK_FAILED"), YES);
}

- (void)libraryChanged {
    // The playing file was deleted from the Downloads screen.
    if (self.currentItem && ![NSFileManager.defaultManager fileExistsAtPath:self.currentItem.fileURL.path]) [self stop];
}

- (void)periodicTick {
    if (!self.currentItem || !self.isPlaying) return;
    if (fabs(self.currentTime - self.lastSavedPosition) >= 5) [self saveResumePosition];
}

- (void)saveResumePosition {
    if (!self.currentItem || !self.player.currentItem) return;
    NSTimeInterval time = self.currentTime;
    NSTimeInterval duration = self.duration;
    // Nearly finished counts as watched.
    if (duration > 0 && time > duration - 10) time = 0;
    if (time < 5) time = 0;
    [[YMDownloadLibrary sharedLibrary] setResumePosition:time forItem:self.currentItem];
    self.lastSavedPosition = time;
}

#pragma mark Background / PiP

- (void)registerPlayerLayer:(AVPlayerLayer *)layer {
    [self.layers addObject:layer];
    layer.player = self.inBackground ? nil : self.player;
}

- (void)appDidEnterBackground {
    self.inBackground = YES;
    // With the video on screen, Picture in Picture starts automatically and needs
    // the layer; it may not report active yet at this point.
    if (self.pictureInPicture.isPictureInPictureActive) return;
    if (ymPlayerPresented && self.pictureInPicture && self.currentItem.isVideo && self.isPlaying) return;
    for (AVPlayerLayer *layer in self.layers) layer.player = nil;
}

- (void)appWillEnterForeground {
    self.inBackground = NO;
    for (AVPlayerLayer *layer in self.layers) layer.player = self.player;
}

#pragma mark Now playing

- (UIImage *)artworkForItem:(YMDownloadItem *)item {
    NSString *path = item.thumbnailURL.path;
    if (!path) return nil;
    UIImage *image = [self.artwork objectForKey:path];
    if (!image) {
        image = [UIImage imageWithContentsOfFile:path];
        if (image) [self.artwork setObject:image forKey:path];
    }
    return image;
}

- (void)updateNowPlaying {
    YMDownloadItem *item = self.currentItem;
    if (!item) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = item.title ?: @"";
    if (item.author.length) info[MPMediaItemPropertyArtist] = item.author;
    info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.isPlaying ? self.rate : 0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(self.rate);
    info[MPNowPlayingInfoPropertyMediaType] = @(item.isVideo ? MPNowPlayingInfoMediaTypeVideo : MPNowPlayingInfoMediaTypeAudio);
    if (self.order.count > 1) {
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = @(self.position);
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = @(self.order.count);
    }
    UIImage *image = [self artworkForItem:item];
    if (image) {
        info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size) { return image; }];
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

// YouTube keeps its own handlers on these commands; they're tagged with the time so
// the -play hook below can tell a lock-screen press from the user resuming YouTube.
- (void)installRemoteCommands {
    if (self.commandTargets.count) return;
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    __weak typeof(self) weakSelf = self;
    id (^add)(MPRemoteCommand *, void (^)(MPRemoteCommandEvent *)) = ^id(MPRemoteCommand *command, void (^action)(MPRemoteCommandEvent *)) {
        command.enabled = YES;
        id token = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            ymLastRemoteCommandTime = NSDate.timeIntervalSinceReferenceDate;
            if (!weakSelf.currentItem) return MPRemoteCommandHandlerStatusNoSuchContent;
            action(event);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        return @[command, token];
    };
    [self.commandTargets addObject:add(center.playCommand, ^(MPRemoteCommandEvent *e) { [weakSelf play]; })];
    [self.commandTargets addObject:add(center.pauseCommand, ^(MPRemoteCommandEvent *e) { [weakSelf pause]; })];
    [self.commandTargets addObject:add(center.togglePlayPauseCommand, ^(MPRemoteCommandEvent *e) { [weakSelf togglePlayPause]; })];
    [self.commandTargets addObject:add(center.nextTrackCommand, ^(MPRemoteCommandEvent *e) { [weakSelf next]; })];
    [self.commandTargets addObject:add(center.previousTrackCommand, ^(MPRemoteCommandEvent *e) { [weakSelf previous]; })];
    [self.commandTargets addObject:add(center.changePlaybackPositionCommand, ^(MPRemoteCommandEvent *e) {
        [weakSelf seekToTime:((MPChangePlaybackPositionCommandEvent *)e).positionTime];
    })];
    center.skipForwardCommand.enabled = NO;
    center.skipBackwardCommand.enabled = NO;
}

- (void)removeRemoteCommands {
    for (NSArray *pair in self.commandTargets) [(MPRemoteCommand *)pair[0] removeTarget:pair[1]];
    [self.commandTargets removeAllObjects];
}

@end

// When YouTube's own player starts while a download is playing: a lock-screen /
// headphone press reaches YouTube's handlers too, so a play right after one of ours
// is undone; anything else is the user going back to YouTube, so ours pauses.
%hook YTPlayerViewController
- (void)play {
    YMLocalPlayback *local = [YMLocalPlayback sharedPlayback];
    if (local.currentItem && local.isPlaying) {
        if (NSDate.timeIntervalSinceReferenceDate - ymLastRemoteCommandTime < 0.5) return;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSDate.timeIntervalSinceReferenceDate - ymLastRemoteCommandTime < 0.6) [weakSelf pause];
            else [local pause];
        });
    }
    %orig;
}
%end

#pragma mark - Player layer view

@interface YMPlayerLayerView : UIView
@property (nonatomic, readonly) AVPlayerLayer *playerLayer;
@end

@implementation YMPlayerLayerView
+ (Class)layerClass { return AVPlayerLayer.class; }
- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }
@end

#pragma mark - Full player

@interface YMLocalPlayerViewController : UIViewController <AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *topBand;
@property (nonatomic, strong) UIView *videoContainer;
@property (nonatomic, strong) YMPlayerLayerView *videoView;
@property (nonatomic, strong) UIImageView *artworkBackground;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UIView *controls;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UIButton *pipButton;
@property (nonatomic, strong) UIButton *speedButton;
@property (nonatomic, strong) AVRoutePickerView *routePicker;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UIButton *fullscreenButton;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UIProgressView *progressLine;
@property (nonatomic, strong) UILabel *seekFeedback;
@property (nonatomic, strong) UIScrollView *infoScroll;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *channelLabel;
@property (nonatomic, strong) UIImageView *channelIcon;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIScrollView *actionsScroll;
@property (nonatomic, strong) UIStackView *actionsStack;
@property (nonatomic, strong) AVPictureInPictureController *pictureInPicture;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSTimer *hideTimer;
@property (nonatomic, assign) BOOL controlsVisible;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, assign) UIInterfaceOrientationMask orientationMask;
@property (nonatomic, assign) CGFloat dragOffset;
// Everything lives in `content`, which follows the dismiss drag over a snapshot of
// the screen underneath (a full-screen presentation removes the real one, but only
// a full-screen presentation may rotate to landscape).
@property (nonatomic, strong) UIView *content;
@property (nonatomic, strong) UIView *backdrop;
@end

static YMLocalPlayerViewController *ymSharedPlayerViewController;

static void YMRequestOrientation(UIViewController *vc, UIInterfaceOrientationMask mask, UIInterfaceOrientation fallback) {
    if (@available(iOS 16.0, *)) {
        [vc setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowScene *scene = vc.view.window.windowScene;
        Class prefsClass = NSClassFromString(@"UIWindowSceneGeometryPreferencesIOS");
        if (scene && prefsClass) {
            id prefs = [[prefsClass alloc] initWithInterfaceOrientations:mask];
            [scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
        }
    } else {
        [UIDevice.currentDevice setValue:@(fallback) forKey:@"orientation"];
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

@implementation YMLocalPlayerViewController

- (instancetype)init {
    if ((self = [super init])) {
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalPresentationCapturesStatusBarAppearance = YES;
        self.orientationMask = UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return self;
}

- (UIButton *)controlButton:(NSString *)symbol size:(CGFloat)size action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:YMSymbol(symbol, size, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.35;
    button.layer.shadowRadius = 4;
    button.layer.shadowOffset = CGSizeZero;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.content = [[UIView alloc] initWithFrame:self.view.bounds];
    self.content.backgroundColor = UIColor.systemBackgroundColor;
    [self.view addSubview:self.content];
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];

    self.topBand = [UIView new];
    self.topBand.backgroundColor = UIColor.blackColor;
    [self.content addSubview:self.topBand];

    self.videoContainer = [UIView new];
    self.videoContainer.backgroundColor = UIColor.blackColor;
    self.videoContainer.clipsToBounds = YES;
    [self.content addSubview:self.videoContainer];

    self.artworkBackground = [UIImageView new];
    self.artworkBackground.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkBackground.clipsToBounds = YES;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
    blur.frame = self.artworkBackground.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.artworkBackground addSubview:blur];
    [self.videoContainer addSubview:self.artworkBackground];

    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFit;
    [self.videoContainer addSubview:self.artworkView];

    self.videoView = [YMPlayerLayerView new];
    self.videoView.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    [playback registerPlayerLayer:self.videoView.playerLayer];
    [self.videoContainer addSubview:self.videoView];

    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        self.pictureInPicture = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.videoView.playerLayer];
        self.pictureInPicture.delegate = self;
        if (@available(iOS 14.2, *)) self.pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = YES;
        playback.pictureInPicture = self.pictureInPicture;
    }

    [self buildControls];
    [self buildInfo];

    self.seekFeedback = [UILabel new];
    self.seekFeedback.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.seekFeedback.textColor = UIColor.whiteColor;
    self.seekFeedback.textAlignment = NSTextAlignmentCenter;
    self.seekFeedback.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.seekFeedback.layer.cornerRadius = 18;
    self.seekFeedback.clipsToBounds = YES;
    self.seekFeedback.alpha = 0;
    [self.videoContainer addSubview:self.seekFeedback];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoDoubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.videoContainer addGestureRecognizer:doubleTap];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoTapped:)];
    [tap requireGestureRecognizerToFail:doubleTap];
    [self.videoContainer addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dismissPan:)];
    pan.delegate = self;
    [self.view addGestureRecognizer:pan];

    __weak typeof(self) weakSelf = self;
    self.timeObserver = [playback.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.25, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        [weakSelf updateTime];
    }];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(itemChanged) name:YMLocalPlaybackItemDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stateChanged) name:YMLocalPlaybackStateDidChangeNotification object:nil];
    [self itemChanged];
    [self setControlsVisible:YES animated:NO];
}

- (void)buildControls {
    self.controls = [UIView new];
    self.controls.backgroundColor = [UIColor colorWithWhite:0 alpha:0.38];
    [self.videoContainer addSubview:self.controls];

    self.collapseButton = [self controlButton:@"chevron.down" size:20 action:@selector(collapse)];
    self.pipButton = [self controlButton:@"pip.enter" size:18 action:@selector(togglePictureInPicture)];
    self.pipButton.hidden = self.pictureInPicture == nil;
    self.speedButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.speedButton.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    self.speedButton.tintColor = UIColor.whiteColor;
    self.speedButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    self.speedButton.layer.cornerRadius = 13;
    self.speedButton.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    self.speedButton.showsMenuAsPrimaryAction = YES;
    self.routePicker = [AVRoutePickerView new];
    self.routePicker.tintColor = UIColor.whiteColor;
    self.routePicker.activeTintColor = UIColor.systemRedColor;
    if (@available(iOS 13.0, *)) self.routePicker.prioritizesVideoDevices = YES;

    self.previousButton = [self controlButton:@"backward.end.fill" size:24 action:@selector(previousTapped)];
    self.playButton = [self controlButton:@"play.fill" size:34 action:@selector(playTapped)];
    self.playButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    self.playButton.layer.cornerRadius = 32;
    self.nextButton = [self controlButton:@"forward.end.fill" size:24 action:@selector(nextTapped)];

    self.timeLabel = [UILabel new];
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    self.timeLabel.textColor = UIColor.whiteColor;
    self.fullscreenButton = [self controlButton:@"arrow.up.left.and.arrow.down.right" size:16 action:@selector(toggleFullscreen)];

    for (UIView *view in @[self.collapseButton, self.pipButton, self.speedButton, self.routePicker, self.previousButton, self.playButton, self.nextButton, self.timeLabel, self.fullscreenButton]) {
        [self.controls addSubview:view];
    }

    self.slider = [UISlider new];
    self.slider.minimumTrackTintColor = UIColor.systemRedColor;
    self.slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.3];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(14, 14)];
    UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemRedColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 14, 14)] fill];
    }];
    [self.slider setThumbImage:thumb forState:UIControlStateNormal];
    [self.slider addTarget:self action:@selector(sliderBegan) forControlEvents:UIControlEventTouchDown];
    [self.slider addTarget:self action:@selector(sliderChanged) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(sliderEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.videoContainer addSubview:self.slider];

    self.progressLine = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.progressLine.progressTintColor = UIColor.systemRedColor;
    self.progressLine.trackTintColor = [UIColor colorWithWhite:1 alpha:0.2];
    [self.videoContainer addSubview:self.progressLine];
}

- (UIButton *)actionPill:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setImage:YMSymbol(symbol, 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = UIColor.tertiarySystemFillColor;
    button.layer.cornerRadius = 17;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 14, 0, 16);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    [button.heightAnchor constraintEqualToConstant:34].active = YES;
    [button addAction:[UIAction actionWithHandler:^(UIAction *a) { action(); }] forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buildInfo {
    self.infoScroll = [UIScrollView new];
    self.infoScroll.alwaysBounceVertical = YES;
    [self.content addSubview:self.infoScroll];

    self.titleLabel = [UILabel new];
    self.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    self.titleLabel.numberOfLines = 0;
    self.metaLabel = [UILabel new];
    self.metaLabel.font = [UIFont systemFontOfSize:13];
    self.metaLabel.textColor = UIColor.secondaryLabelColor;
    self.metaLabel.numberOfLines = 0;
    self.channelIcon = [[UIImageView alloc] initWithImage:YMSymbol(@"person.crop.circle.fill", 30, UIImageSymbolWeightRegular)];
    self.channelIcon.tintColor = UIColor.tertiaryLabelColor;
    self.channelIcon.contentMode = UIViewContentModeCenter;
    self.channelLabel = [UILabel new];
    self.channelLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];

    self.actionsScroll = [UIScrollView new];
    self.actionsScroll.showsHorizontalScrollIndicator = NO;
    self.actionsStack = [UIStackView new];
    self.actionsStack.axis = UILayoutConstraintAxisHorizontal;
    self.actionsStack.spacing = 8;
    self.actionsStack.alignment = UIStackViewAlignmentCenter;
    [self.actionsScroll addSubview:self.actionsStack];

    for (UIView *view in @[self.titleLabel, self.metaLabel, self.channelIcon, self.channelLabel, self.actionsScroll]) {
        [self.infoScroll addSubview:view];
    }
}

- (void)rebuildActions {
    for (UIView *view in self.actionsStack.arrangedSubviews) [view removeFromSuperview];
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    YMDownloadItem *item = playback.currentItem;
    if (!item) return;
    __weak typeof(self) weakSelf = self;

    NSString *repeatSymbol = playback.repeatMode == YMRepeatModeOne ? @"repeat.1" : @"repeat";
    NSString *repeatTitle = playback.repeatMode == YMRepeatModeOne ? LOC(@"PLAYER_REPEAT_ONE") : (playback.repeatMode == YMRepeatModeAll ? LOC(@"PLAYER_REPEAT_ALL") : LOC(@"PLAYER_REPEAT"));
    UIButton *repeat = [self actionPill:repeatTitle symbol:repeatSymbol action:^{
        YMLocalPlayback *p = [YMLocalPlayback sharedPlayback];
        p.repeatMode = (p.repeatMode + 1) % 3;
    }];
    if (playback.repeatMode != YMRepeatModeOff) { repeat.backgroundColor = UIColor.labelColor; repeat.tintColor = UIColor.systemBackgroundColor; }
    [self.actionsStack addArrangedSubview:repeat];

    UIButton *shuffle = [self actionPill:LOC(@"PLAYER_SHUFFLE") symbol:@"shuffle" action:^{
        YMLocalPlayback *p = [YMLocalPlayback sharedPlayback];
        p.shuffle = !p.shuffle;
    }];
    if (playback.shuffle) { shuffle.backgroundColor = UIColor.labelColor; shuffle.tintColor = UIColor.systemBackgroundColor; }
    [self.actionsStack addArrangedSubview:shuffle];

    [self.actionsStack addArrangedSubview:[self actionPill:LOC(@"SHARE") symbol:@"square.and.arrow.up" action:^{
        YMDownloadShareFile(item.fileURL, weakSelf);
    }]];
    if (item.isVideo) {
        [self.actionsStack addArrangedSubview:[self actionPill:LOC(@"SAVE_TO_PHOTOS_ACTION") symbol:@"photo.on.rectangle" action:^{
            YMDownloadSaveVideoToPhotos(item.fileURL, weakSelf);
        }]];
    }
    if (item.videoID.length) {
        [self.actionsStack addArrangedSubview:[self actionPill:LOC(@"OPEN_VIDEO") symbol:@"play.rectangle" action:^{
            NSURL *url = [NSURL URLWithString:[@"youtube://" stringByAppendingString:item.videoID]];
            [[YMLocalPlayback sharedPlayback] pause];
            [weakSelf collapseThen:^{ [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil]; }];
        }]];
        [self.actionsStack addArrangedSubview:[self actionPill:LOC(@"COPY_LINK") symbol:@"link" action:^{
            UIPasteboard.generalPasteboard.string = [@"https://youtu.be/" stringByAppendingString:item.videoID];
            YMDownloadShowToast(LOC(@"COPIED_TO_CLIPBOARD"), NO);
        }]];
    }
    UIButton *delete = [self actionPill:LOC(@"DELETE") symbol:@"trash" action:^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"DELETE_DOWNLOAD") message:item.title preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            YMLocalPlayback *p = [YMLocalPlayback sharedPlayback];
            if (p.hasNext) [p next]; else [p stop];
            [[YMDownloadLibrary sharedLibrary] removeItem:item];
        }]];
        [weakSelf presentViewController:alert animated:YES completion:nil];
    }];
    delete.tintColor = UIColor.systemRedColor;
    [self.actionsStack addArrangedSubview:delete];
    [self.view setNeedsLayout];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.timeObserver) [[YMLocalPlayback sharedPlayback].player removeTimeObserver:self.timeObserver];
}

#pragma mark Layout

- (BOOL)isLandscape {
    return self.view.bounds.size.width > self.view.bounds.size.height;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.backdrop.frame = bounds;
    if (CGAffineTransformIsIdentity(self.content.transform)) self.content.frame = bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    BOOL landscape = [self isLandscape];

    CGRect videoFrame;
    if (landscape) {
        videoFrame = bounds;
        self.topBand.frame = CGRectZero;
    } else {
        CGFloat height = round(bounds.size.width * 9.0 / 16.0);
        videoFrame = CGRectMake(0, safe.top, bounds.size.width, height);
        self.topBand.frame = CGRectMake(0, 0, bounds.size.width, safe.top);
    }
    self.videoContainer.frame = videoFrame;
    CGRect local = self.videoContainer.bounds;
    self.videoView.frame = local;
    self.artworkBackground.frame = local;
    self.artworkView.frame = CGRectInset(local, 0, 12);
    self.controls.frame = local;
    self.content.backgroundColor = landscape ? UIColor.blackColor : UIColor.systemBackgroundColor;

    // Controls. In landscape keep them inside the safe area (notch, home indicator).
    UIEdgeInsets inner = landscape ? UIEdgeInsetsMake(MAX(safe.top, 8), MAX(safe.left, 12), MAX(safe.bottom, 8), MAX(safe.right, 12)) : UIEdgeInsetsMake(4, 8, 0, 8);
    CGFloat w = local.size.width, h = local.size.height;
    self.collapseButton.frame = CGRectMake(inner.left, inner.top, 40, 40);
    CGFloat x = w - inner.right - 40;
    self.routePicker.frame = CGRectMake(x, inner.top + 3, 34, 34);
    x -= 40;
    self.pipButton.frame = CGRectMake(x, inner.top, 40, 40);
    if (!self.pipButton.hidden) x -= 4;
    CGSize speedSize = [self.speedButton sizeThatFits:CGSizeMake(80, 26)];
    speedSize.height = 26;
    self.speedButton.frame = CGRectMake((self.pipButton.hidden ? x + 40 : x) - speedSize.width - 4, inner.top + 7, speedSize.width, speedSize.height);

    CGFloat centerY = h / 2;
    self.playButton.frame = CGRectMake(w / 2 - 32, centerY - 32, 64, 64);
    CGFloat spread = MIN(w * 0.22, 140);
    self.previousButton.frame = CGRectMake(w / 2 - spread - 24, centerY - 24, 48, 48);
    self.nextButton.frame = CGRectMake(w / 2 + spread - 24, centerY - 24, 48, 48);

    CGFloat sliderY = landscape ? h - inner.bottom - 30 : h - 15;
    self.slider.frame = landscape ? CGRectMake(inner.left, sliderY, w - inner.left - inner.right, 30) : CGRectMake(-2, sliderY, w + 4, 30);
    self.progressLine.frame = CGRectMake(0, h - 2.5, w, 2.5);
    CGFloat timeY = landscape ? sliderY - 30 : h - 46;
    self.timeLabel.frame = CGRectMake(inner.left + 6, timeY, 200, 24);
    self.fullscreenButton.frame = CGRectMake(w - inner.right - 40, timeY - 8, 40, 40);
    self.seekFeedback.bounds = CGRectMake(0, 0, 92, 36);

    // In portrait the video sits on the page edge like YouTube's; keep its scrubber
    // reachable by letting it overhang the video into the page.
    self.videoContainer.clipsToBounds = landscape;
    self.infoScroll.hidden = landscape;
    if (landscape) return;

    CGFloat top = CGRectGetMaxY(videoFrame) + 16;
    self.infoScroll.frame = CGRectMake(0, top, bounds.size.width, bounds.size.height - top);
    CGFloat margin = 16;
    CGFloat width = bounds.size.width - margin * 2 - safe.left - safe.right;
    CGFloat y = 4;
    CGSize titleSize = [self.titleLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.titleLabel.frame = CGRectMake(margin + safe.left, y, width, titleSize.height);
    y += titleSize.height + 6;
    CGSize metaSize = [self.metaLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.metaLabel.frame = CGRectMake(margin + safe.left, y, width, metaSize.height);
    y += metaSize.height + 16;
    BOOL hasChannel = self.channelLabel.text.length > 0;
    self.channelIcon.hidden = self.channelLabel.hidden = !hasChannel;
    if (hasChannel) {
        self.channelIcon.frame = CGRectMake(margin + safe.left, y, 36, 36);
        self.channelLabel.frame = CGRectMake(margin + safe.left + 46, y, width - 46, 36);
        y += 36 + 16;
    }
    CGSize stackSize = [self.actionsStack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    self.actionsScroll.frame = CGRectMake(0, y, bounds.size.width, 34);
    self.actionsStack.frame = CGRectMake(margin + safe.left, 0, stackSize.width, 34);
    self.actionsScroll.contentSize = CGSizeMake(stackSize.width + margin * 2 + safe.left, 34);
    y += 34 + 24;
    self.infoScroll.contentSize = CGSizeMake(bounds.size.width, y + safe.bottom);
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(id context) {
        [self updateFullscreenButton];
        [self setNeedsStatusBarAppearanceUpdate];
        if (@available(iOS 11.0, *)) [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    } completion:nil];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return isPad() ? UIInterfaceOrientationMaskAll : self.orientationMask;
}

- (BOOL)prefersStatusBarHidden { return [self isLandscape]; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
- (BOOL)prefersHomeIndicatorAutoHidden { return [self isLandscape]; }

#pragma mark State

- (void)itemChanged {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    YMDownloadItem *item = playback.currentItem;
    if (!item) {
        if (self.presentingViewController && !self.isBeingDismissed) [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    self.titleLabel.text = item.title;
    self.channelLabel.text = item.author;
    NSMutableArray *meta = [NSMutableArray array];
    if (item.formatSummary.length) [meta addObject:item.formatSummary];
    if (item.fileSize) [meta addObject:[NSByteCountFormatter stringFromByteCount:(long long)item.fileSize countStyle:NSByteCountFormatterCountStyleFile]];
    if (item.createdAt > 0) {
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:item.createdAt];
        [meta addObject:[NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle]];
    }
    self.metaLabel.text = [meta componentsJoinedByString:@" · "];

    UIImage *artwork = [playback artworkForItem:item];
    self.artworkBackground.image = artwork;
    self.artworkView.image = artwork ?: YMSymbol(@"music.note", 44, UIImageSymbolWeightRegular);
    self.artworkView.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
    self.artworkBackground.hidden = self.artworkView.hidden = item.isVideo;
    self.videoView.hidden = !item.isVideo;
    self.pipButton.hidden = !item.isVideo || self.pictureInPicture == nil;
    self.fullscreenButton.hidden = !item.isVideo;
    [self rebuildActions];
    [self stateChanged];
}

- (void)stateChanged {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    [self.playButton setImage:YMSymbol(playback.isPlaying ? @"pause.fill" : @"play.fill", 34, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    self.nextButton.enabled = playback.hasNext;
    self.nextButton.alpha = playback.hasNext ? 1 : 0.4;

    NSString *rateTitle = [self rateTitle:playback.rate];
    [self.speedButton setTitle:rateTitle forState:UIControlStateNormal];
    NSMutableArray *rates = [NSMutableArray array];
    for (NSNumber *value in @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0]) {
        UIAction *action = [UIAction actionWithTitle:[self rateTitle:value.floatValue] image:nil identifier:nil handler:^(UIAction *a) {
            [YMLocalPlayback sharedPlayback].rate = value.floatValue;
        }];
        if (fabsf(value.floatValue - playback.rate) < 0.01) action.state = UIMenuElementStateOn;
        [rates addObject:action];
    }
    self.speedButton.menu = [UIMenu menuWithTitle:LOC(@"PLAYBACK_SPEED") children:rates];
    [self rebuildActionsIfNeeded];
    [self updateTime];
    [self scheduleHide];
    [self.view setNeedsLayout];
}

- (void)rebuildActionsIfNeeded {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    static NSInteger lastRepeat = -1, lastShuffle = -1;
    if (lastRepeat == playback.repeatMode && lastShuffle == playback.shuffle) return;
    lastRepeat = playback.repeatMode;
    lastShuffle = playback.shuffle;
    [self rebuildActions];
}

- (NSString *)rateTitle:(float)rate {
    NSString *number = [NSString stringWithFormat:@"%g", rate];
    return [number stringByAppendingString:@"×"];
}

- (void)updateTime {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    NSTimeInterval duration = playback.duration;
    NSTimeInterval time = self.scrubbing ? self.slider.value * duration : playback.currentTime;
    self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@", YMLocalFormatTime(time), YMLocalFormatTime(duration)];
    if (!self.scrubbing) self.slider.value = duration > 0 ? (float)(time / duration) : 0;
    self.progressLine.progress = duration > 0 ? (float)(time / duration) : 0;
}

#pragma mark Controls

- (void)setControlsVisible:(BOOL)visible animated:(BOOL)animated {
    self.controlsVisible = visible;
    void (^changes)(void) = ^{
        self.controls.alpha = visible ? 1 : 0;
        self.slider.alpha = visible ? 1 : 0;
        self.progressLine.alpha = (visible || [self isLandscape]) ? 0 : 1;
    };
    if (animated) [UIView animateWithDuration:0.2 animations:changes];
    else changes();
    [self scheduleHide];
}

- (void)scheduleHide {
    [self.hideTimer invalidate];
    self.hideTimer = nil;
    if (!self.controlsVisible || ![YMLocalPlayback sharedPlayback].isPlaying || self.scrubbing) return;
    __weak typeof(self) weakSelf = self;
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:3.5 repeats:NO block:^(NSTimer *timer) {
        [weakSelf setControlsVisible:NO animated:YES];
    }];
}

- (void)videoTapped:(UITapGestureRecognizer *)tap {
    [self setControlsVisible:!self.controlsVisible animated:YES];
}

- (void)videoDoubleTapped:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self.videoContainer];
    CGFloat width = self.videoContainer.bounds.size.width;
    if (point.x > width * 0.35 && point.x < width * 0.65) {
        [[YMLocalPlayback sharedPlayback] togglePlayPause];
        return;
    }
    BOOL forward = point.x >= width / 2;
    [[YMLocalPlayback sharedPlayback] seekBy:forward ? 10 : -10];
    self.seekFeedback.text = forward ? @"+10s" : @"−10s";
    self.seekFeedback.center = CGPointMake(forward ? width * 0.78 : width * 0.22, self.videoContainer.bounds.size.height / 2);
    self.seekFeedback.alpha = 1;
    [UIView animateWithDuration:0.3 delay:0.5 options:0 animations:^{ self.seekFeedback.alpha = 0; } completion:nil];
}

- (void)playTapped { [[YMLocalPlayback sharedPlayback] togglePlayPause]; }
- (void)previousTapped { [[YMLocalPlayback sharedPlayback] previous]; [self scheduleHide]; }
- (void)nextTapped { [[YMLocalPlayback sharedPlayback] next]; [self scheduleHide]; }

- (void)sliderBegan {
    self.scrubbing = YES;
    [self.hideTimer invalidate];
}

- (void)sliderChanged {
    [self updateTime];
}

- (void)sliderEnded {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    [playback seekToTime:self.slider.value * playback.duration];
    self.scrubbing = NO;
    [self scheduleHide];
}

- (void)togglePictureInPicture {
    if (!self.pictureInPicture) return;
    if (self.pictureInPicture.isPictureInPictureActive) [self.pictureInPicture stopPictureInPicture];
    else [self.pictureInPicture startPictureInPicture];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    [self collapseThen:nil];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    if (!ymPlayerPresented) YMLocalPlayerPresent(nil);
    completionHandler(YES);
}

- (void)updateFullscreenButton {
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    [self.fullscreenButton setImage:YMSymbol(landscape ? @"arrow.down.right.and.arrow.up.left" : @"arrow.up.left.and.arrow.down.right", 16, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
}

- (void)toggleFullscreen {
    if ([self isLandscape]) {
        self.orientationMask = UIInterfaceOrientationMaskPortrait;
        YMRequestOrientation(self, UIInterfaceOrientationMaskPortrait, UIInterfaceOrientationPortrait);
        // Hand rotation back to the device once it has settled in portrait.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.orientationMask = UIInterfaceOrientationMaskAllButUpsideDown;
            if (@available(iOS 16.0, *)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
        });
    } else {
        self.orientationMask = UIInterfaceOrientationMaskLandscape;
        YMRequestOrientation(self, UIInterfaceOrientationMaskLandscapeRight, UIInterfaceOrientationLandscapeRight);
    }
    [self scheduleHide];
}

#pragma mark Dismiss

- (void)collapse {
    [self collapseThen:nil];
}

- (void)collapseThen:(void (^)(void))completion {
    void (^dismiss)(void) = ^{
        if (!self.presentingViewController) { if (completion) completion(); return; }
        [self dismissViewControllerAnimated:YES completion:completion];
    };
    if ([self isLandscape] && !isPad()) {
        self.orientationMask = UIInterfaceOrientationMaskPortrait;
        YMRequestOrientation(self, UIInterfaceOrientationMaskPortrait, UIInterfaceOrientationPortrait);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), dismiss);
    } else {
        dismiss();
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    ymPlayerPresented = NO;
    self.orientationMask = UIInterfaceOrientationMaskAllButUpsideDown;
    self.content.transform = CGAffineTransformIdentity;
    [self.backdrop removeFromSuperview];
    self.backdrop = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    ymPlayerPresented = YES;
    [self updateFullscreenButton];
    [self setControlsVisible:YES animated:NO];
}

- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)pan {
    if (![pan isKindOfClass:UIPanGestureRecognizer.class] || [self isLandscape]) return NO;
    CGPoint velocity = [pan velocityInView:self.view];
    if (velocity.y <= 0 || fabs(velocity.y) < fabs(velocity.x)) return NO;
    // From the info area only when it is scrolled to the top.
    CGPoint point = [pan locationInView:self.view];
    if (CGRectContainsPoint(self.infoScroll.frame, point) && self.infoScroll.contentOffset.y > 0) return NO;
    return ![self.slider pointInside:[pan locationInView:self.slider] withEvent:nil];
}

- (void)dismissPan:(UIPanGestureRecognizer *)pan {
    CGFloat translation = MAX(0, [pan translationInView:self.view].y);
    switch (pan.state) {
        case UIGestureRecognizerStateBegan:
            self.backdrop.hidden = NO;
            break;
        case UIGestureRecognizerStateChanged:
            self.content.transform = CGAffineTransformMakeTranslation(0, translation);
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat velocity = [pan velocityInView:self.view].y;
            if (pan.state == UIGestureRecognizerStateEnded && (translation > 140 || velocity > 900)) {
                [UIView animateWithDuration:0.22 animations:^{
                    self.content.transform = CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
                } completion:^(BOOL finished) {
                    [self dismissViewControllerAnimated:NO completion:^{ self.content.transform = CGAffineTransformIdentity; }];
                }];
            } else {
                [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
                    self.content.transform = CGAffineTransformIdentity;
                } completion:nil];
            }
            break;
        }
        default:
            break;
    }
}

@end

void YMLocalPlayerPresent(UIViewController *presenter) {
    if (![YMLocalPlayback sharedPlayback].currentItem || ymPlayerPresented) return;
    if (!ymSharedPlayerViewController) ymSharedPlayerViewController = [YMLocalPlayerViewController new];
    if (ymSharedPlayerViewController.presentingViewController) return;
    presenter = YouModTopViewController(presenter);
    if (!presenter) return;
    ymPlayerPresented = YES;
    YMLocalPlayerViewController *player = ymSharedPlayerViewController;
    [player loadViewIfNeeded];
    [player.backdrop removeFromSuperview];
    UIView *snapshot = [presenter.view.window snapshotViewAfterScreenUpdates:NO];
    if (snapshot) {
        UIView *dim = [[UIView alloc] initWithFrame:snapshot.bounds];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
        dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [snapshot addSubview:dim];
        snapshot.hidden = YES; // shown once a dismiss drag starts
        player.backdrop = snapshot;
        [player.view insertSubview:snapshot belowSubview:player.content];
    }
    [presenter presentViewController:player animated:YES completion:nil];
}

%hook YTAppDelegate
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    if (ymPlayerPresented && ymSharedPlayerViewController.viewIfLoaded.window == window) return [ymSharedPlayerViewController supportedInterfaceOrientations];
    return %orig;
}
%end

#pragma mark - Conversion

// Re-encodes a file AVPlayer can't decode into MP4 (H.264, or HEVC above 1080p) /
// M4A (AAC) with the VideoToolbox hardware encoders, replacing the original.
static void YMLocalConvertItem(YMDownloadItem *item, UIViewController *presenter, void (^completion)(BOOL success)) {
    NSURL *input = item.fileURL;
    BOOL video = item.isVideo;
    NSInteger height = 0;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{3,4})p" options:0 error:nil];
    NSTextCheckingResult *match = item.formatSummary ? [regex firstMatchInString:item.formatSummary options:0 range:NSMakeRange(0, item.formatSummary.length)] : nil;
    if (match) height = [[item.formatSummary substringWithRange:[match rangeAtIndex:1]] integerValue];

    NSString *extension = video ? @"mp4" : @"m4a";
    NSURL *output = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
    NSMutableArray *args = [@[@"-y", @"-i", input.path] mutableCopy];
    NSString *videoCodecName = @"H.264";
    if (video) {
        BOOL hevc = height > 1080;
        NSString *bitrate = height >= 2160 ? @"30M" : (height >= 1440 ? @"16M" : (height >= 1080 ? @"8M" : (height >= 720 ? @"5M" : @"8M")));
        if (hevc) videoCodecName = @"HEVC";
        [args addObjectsFromArray:@[@"-map", @"0:v:0", @"-map", @"0:a:0?", @"-c:v", hevc ? @"hevc_videotoolbox" : @"h264_videotoolbox", @"-b:v", bitrate]];
        if (hevc) [args addObjectsFromArray:@[@"-tag:v", @"hvc1"]];
        [args addObjectsFromArray:@[@"-c:a", @"aac", @"-b:a", @"192k", @"-movflags", @"+faststart"]];
    } else {
        [args addObjectsFromArray:@[@"-vn", @"-c:a", @"aac", @"-b:a", @"256k"]];
    }
    [args addObject:output.path];

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:LOC(@"CONVERTING") message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
    __block BOOL cancelled = NO;
    [progressAlert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        cancelled = YES;
        YMFFmpegCancel();
    }]];
    [presenter presentViewController:progressAlert animated:YES completion:nil];

    [UIApplication.sharedApplication setIdleTimerDisabled:YES];
    YMFFmpegRun(args, item.durationMs, ^(float progress) {
        progressAlert.message = [NSString stringWithFormat:@"%d%%", (int)(progress * 100)];
    }, ^(BOOL success, BOOL wasCancelled, NSString *errorMessage) {
        [UIApplication.sharedApplication setIdleTimerDisabled:NO];
        void (^finish)(void) = ^{
            if (success && !cancelled) {
                NSString *summary = item.formatSummary;
                summary = [summary stringByReplacingOccurrencesOfString:@"VP9" withString:videoCodecName];
                summary = [summary stringByReplacingOccurrencesOfString:@"AV1" withString:videoCodecName];
                summary = [summary stringByReplacingOccurrencesOfString:@"Opus" withString:@"AAC"];
                BOOL replaced = [[YMDownloadLibrary sharedLibrary] replaceFileOfItem:item withURL:output formatSummary:summary];
                if (!replaced) YMDownloadShowToast(LOC(@"CONVERSION_FAILED"), YES);
                completion(replaced);
            } else {
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                if (!cancelled && !wasCancelled) YMDownloadShowToast(errorMessage.length ? errorMessage : LOC(@"CONVERSION_FAILED"), YES);
                completion(NO);
            }
        };
        if (progressAlert.presentingViewController) [progressAlert dismissViewControllerAnimated:YES completion:finish];
        else finish();
    });
}

void YMLocalPlayerOpen(UIViewController *presenter, NSArray<YMDownloadItem *> *items, NSUInteger index) {
    if (index >= items.count) return;
    YMDownloadItem *item = items[index];
    presenter = YouModTopViewController(presenter);
    if (![NSFileManager.defaultManager fileExistsAtPath:item.fileURL.path]) {
        YMDownloadShowToast(LOC(@"FILE_NOT_FOUND"), YES);
        [[YMDownloadLibrary sharedLibrary] reload];
        return;
    }
    NSString *unsupported = YMLocalUnsupportedFormat(item.fileURL);
    if (!unsupported) {
        YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
        if (playback.currentItem != item) [playback playItems:items startAtIndex:index];
        else [playback play];
        YMLocalPlayerPresent(presenter);
        return;
    }

    NSString *message = [NSString stringWithFormat:LOC(@"UNSUPPORTED_FORMAT_MESSAGE"), unsupported];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOC(@"UNSUPPORTED_FORMAT_TITLE") message:message preferredStyle:UIAlertControllerStyleAlert];
    if (YMFFmpegInstalled()) {
        [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CONVERT") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            YMLocalConvertItem(item, presenter, ^(BOOL success) {
                if (success) YMLocalPlayerOpen(presenter, items, index);
            });
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"OPEN_IN") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        YMDownloadShareFile(item.fileURL, presenter);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Mini player bar

@interface YMLocalMiniPlayerBar ()
@property (nonatomic, strong) UIVisualEffectView *background;
@property (nonatomic, strong) UIView *thumbContainer;
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) YMPlayerLayerView *videoView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) id timeObserver;
@end

@implementation YMLocalMiniPlayerBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        self.background = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        self.background.layer.cornerRadius = 14;
        self.background.clipsToBounds = YES;
        [self addSubview:self.background];
        UIView *content = self.background.contentView;

        self.thumbContainer = [UIView new];
        self.thumbContainer.backgroundColor = UIColor.blackColor;
        self.thumbContainer.layer.cornerRadius = 7;
        self.thumbContainer.clipsToBounds = YES;
        [content addSubview:self.thumbContainer];
        self.thumbView = [UIImageView new];
        self.thumbView.contentMode = UIViewContentModeScaleAspectFill;
        self.thumbView.clipsToBounds = YES;
        [self.thumbContainer addSubview:self.thumbView];
        self.videoView = [YMPlayerLayerView new];
        self.videoView.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [[YMLocalPlayback sharedPlayback] registerPlayerLayer:self.videoView.playerLayer];
        [self.thumbContainer addSubview:self.videoView];

        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        self.subtitleLabel = [UILabel new];
        self.subtitleLabel.font = [UIFont systemFontOfSize:12];
        self.subtitleLabel.textColor = UIColor.secondaryLabelColor;
        [content addSubview:self.titleLabel];
        [content addSubview:self.subtitleLabel];

        self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.playButton.tintColor = UIColor.labelColor;
        [self.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
        self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.closeButton.tintColor = UIColor.labelColor;
        [self.closeButton setImage:YMSymbol(@"xmark", 17, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
        [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [content addSubview:self.playButton];
        [content addSubview:self.closeButton];

        self.progressTrack = [UIView new];
        self.progressTrack.backgroundColor = UIColor.quaternaryLabelColor;
        self.progressFill = [UIView new];
        self.progressFill.backgroundColor = UIColor.systemRedColor;
        [content addSubview:self.progressTrack];
        [self.progressTrack addSubview:self.progressFill];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(open)]];
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(open)];
        swipe.direction = UISwipeGestureRecognizerDirectionUp;
        [self addGestureRecognizer:swipe];

        __weak typeof(self) weakSelf = self;
        self.timeObserver = [[YMLocalPlayback sharedPlayback].player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
            [weakSelf setNeedsLayout];
        }];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:YMLocalPlaybackItemDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:YMLocalPlaybackStateDidChangeNotification object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.timeObserver) [[YMLocalPlayback sharedPlayback].player removeTimeObserver:self.timeObserver];
}

- (void)refresh {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    YMDownloadItem *item = playback.currentItem;
    self.titleLabel.text = item.title;
    self.subtitleLabel.text = item.author.length ? item.author : item.formatSummary;
    self.thumbView.image = [playback artworkForItem:item];
    self.videoView.hidden = !item.isVideo;
    [self.playButton setImage:YMSymbol(playback.isPlaying ? @"pause.fill" : @"play.fill", 20, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.background.frame = self.bounds;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:14].CGPath;
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    CGFloat thumbH = h - 16;
    self.thumbContainer.frame = CGRectMake(8, 8, round(thumbH * 16 / 9), thumbH);
    self.thumbView.frame = self.thumbContainer.bounds;
    self.videoView.frame = self.thumbContainer.bounds;
    self.closeButton.frame = CGRectMake(w - 44, (h - 44) / 2, 40, 44);
    self.playButton.frame = CGRectMake(w - 84, (h - 44) / 2, 40, 44);
    CGFloat textX = CGRectGetMaxX(self.thumbContainer.frame) + 10;
    CGFloat textW = CGRectGetMinX(self.playButton.frame) - textX - 4;
    self.titleLabel.frame = CGRectMake(textX, h / 2 - 19, textW, 20);
    self.subtitleLabel.frame = CGRectMake(textX, h / 2 + 1, textW, 18);
    self.progressTrack.frame = CGRectMake(0, h - 2, w, 2);
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    CGFloat fraction = playback.duration > 0 ? playback.currentTime / playback.duration : 0;
    self.progressFill.frame = CGRectMake(0, 0, w * MIN(MAX(fraction, 0), 1), 2);
}

- (void)playTapped { [[YMLocalPlayback sharedPlayback] togglePlayPause]; }
- (void)closeTapped { [[YMLocalPlayback sharedPlayback] stop]; }
- (void)open { if (self.openHandler) self.openHandler(); }

@end

CGFloat YMLocalMiniPlayerBarHeight(void) { return YMMiniBarHeight; }
