// Player for finished downloads (see LocalPlayer.h). Modeled on uYou's
// PlayerManager/PlayerVC: one AVPlayer shared by a full-screen watch page and a
// mini bar, with a queue (next/previous, repeat, shuffle) taken from the list the
// item was started from, and system now-playing integration.
#import "Headers.h"
#import "DownloadLibrary.h"
#import "DownloadQueue.h"
#import "LocalPlayer.h"
#import "LocalPlayerEngine.h"
#import "FFmpegKit.h"
#import <AVKit/AVKit.h>
#import <objc/message.h>
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


#pragma mark - YouTube / YouMod settings

// YouTube's own "Double-tap to seek" setting (Settings > General): -[YTUserDefaults
// doubleTapSeekDuration] returns the stored seconds, 5/10/15/20/30/60, else 10.
// YTUserDefaults has no shared accessor, so the instance is picked up the first
// time YouTube reads any of its keyed settings (each goes through keysProvider).
static __weak id ymYTUserDefaults;

%hook YTUserDefaults
- (id)keysProvider {
    ymYTUserDefaults = self;
    return %orig;
}
%end

static NSTimeInterval YMDoubleTapSeekSeconds(void) {
    id defaults = ymYTUserDefaults;
    NSInteger seconds = [defaults respondsToSelector:@selector(doubleTapSeekDuration)] ? ((NSInteger (*)(id, SEL))objc_msgSend)(defaults, @selector(doubleTapSeekDuration)) : 10;
    switch (seconds) {
        case 5: case 10: case 15: case 20: case 30: case 60: return seconds;
        default: return 10;
    }
}

// YouMod raises the speed limit to 10x whenever one of its speed features is on
// (the same condition it uses for YouTube's player), otherwise YouTube's 2x.
static float YMMaximumRate(void) {
    BOOL extra = IS_ENABLED(ExtraSpeed) || IS_ENABLED(GestureControls) || INTFORVAL(HoldToSpeedIndex) >= 9 || INTFORVAL(AutoSpeedIndex) >= 9;
    return extra ? 10.0f : 2.0f;
}

// The speed menu: YouMod's extended list, or YouTube's own.
static NSArray<NSNumber *> *YMSpeedOptions(void) {
    if (YMMaximumRate() > 2.0f) return @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @2.5, @3.0, @5.0, @7.5, @10.0];
    return @[@0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0];
}

static NSTimeInterval YMSkipSeconds(NSString *key) {
    double value = [NSUserDefaults.standardUserDefaults doubleForKey:key];
    return value > 0 ? value : 10;
}

#pragma mark - Playback

@interface YMLocalPlayback ()
@property (nonatomic, strong, readwrite) YMDownloadItem *currentItem;
@property (nonatomic, copy) NSArray<YMDownloadItem *> *queue;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order; // play order (indices into queue)
@property (nonatomic, assign) NSUInteger position;               // index into order
@property (nonatomic, strong) YMNativeEngine *nativeEngine;
@property (nonatomic, strong) YMVLCEngine *vlcEngine;
@property (nonatomic, strong) id<YMPlaybackEngine> engine;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, strong) NSMutableArray *commandTargets;
@property (nonatomic, strong) NSHashTable<YMLocalVideoView *> *videoViews;
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *artwork;
@property (nonatomic, assign) BOOL inBackground;
@property (nonatomic, assign) NSTimeInterval lastSavedPosition;
@property (nonatomic, weak) AVPictureInPictureController *pictureInPicture;
@property (nonatomic, readonly) YMPlaybackRoute route;
- (void)registerVideoView:(YMLocalVideoView *)view;
@end

// The engine that can play a file: AVPlayer when AVFoundation decodes it, VLC for
// everything else (when MobileVLCKit is installed).
static YMPlaybackRoute YMLocalRouteForURL(NSURL *url, BOOL *playable) {
    if (!YMLocalUnsupportedFormat(url)) { if (playable) *playable = YES; return YMPlaybackRouteNative; }
    BOOL vlc = [YMVLCEngine isAvailable];
    if (playable) *playable = vlc;
    return YMPlaybackRouteVLC;
}

@implementation YMLocalPlayback

+ (instancetype)sharedPlayback {
    static YMLocalPlayback *playback;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ playback = [YMLocalPlayback new]; });
    return playback;
}

- (instancetype)init {
    if ((self = [super init])) {
        _rate = 1.0f;
        _volume = 1.0f;
        _muted = [NSUserDefaults.standardUserDefaults boolForKey:KeepMutedKey];
        _videoViews = [NSHashTable weakObjectsHashTable];
        _artwork = [NSCache new];
        _commandTargets = [NSMutableArray array];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
        [center addObserver:self selector:@selector(libraryChanged) name:YMDownloadLibraryDidChangeNotification object:nil];
    }
    return self;
}

- (id<YMPlaybackEngine>)engineForRoute:(YMPlaybackRoute)route {
    if (route == YMPlaybackRouteVLC) {
        if (!self.vlcEngine) self.vlcEngine = [YMVLCEngine new];
        return self.vlcEngine;
    }
    if (!self.nativeEngine) self.nativeEngine = [YMNativeEngine new];
    return self.nativeEngine;
}

- (void)switchToEngine:(id<YMPlaybackEngine>)engine {
    if (engine == self.engine) return;
    [self.engine stop];
    self.engine.stateHandler = nil;
    self.engine.endHandler = nil;
    self.engine.failureHandler = nil;
    self.engine = engine;
    __weak typeof(self) weakSelf = self;
    engine.stateHandler = ^{ [weakSelf engineStateChanged]; };
    engine.endHandler = ^{ [weakSelf engineReachedEnd]; };
    engine.failureHandler = ^{ [weakSelf engineFailed]; };
    [engine setRate:self.rate];
    [engine setVolume:MIN(self.volume, engine.maximumVolume)];
    [engine setMuted:self.muted];
    for (YMLocalVideoView *view in self.videoViews) [engine attachVideoView:view];
}

- (float)maximumVolume {
    return self.engine ? self.engine.maximumVolume : 1.0f;
}

- (void)setVolume:(float)volume {
    _volume = MIN(MAX(volume, 0), self.maximumVolume);
    [self.engine setVolume:_volume];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    [NSUserDefaults.standardUserDefaults setBool:muted forKey:KeepMutedKey];
    [self.engine setMuted:muted];
    [self postState];
}

- (void)setAudioOnly:(BOOL)audioOnly {
    _audioOnly = audioOnly;
    [self updateVideoSuspension];
    [self postState];
}

- (void)updateVideoSuspension {
    BOOL suspended = self.audioOnly;
    if (self.inBackground && !self.pictureInPicture.isPictureInPictureActive &&
        !(ymPlayerPresented && self.pictureInPicture && self.currentItem.isVideo && self.isPlaying)) suspended = YES;
    [self.engine setVideoSuspended:suspended];
}

- (YMPlaybackRoute)route {
    return self.engine ? self.engine.route : YMPlaybackRouteNative;
}

- (void)postState {
    [NSNotificationCenter.defaultCenter postNotificationName:YMLocalPlaybackStateDidChangeNotification object:self];
}

- (void)engineStateChanged {
    [self updateNowPlaying];
    [self postState];
}

- (BOOL)isPlaying {
    return self.currentItem && self.engine.isPlaying;
}

- (NSTimeInterval)currentTime {
    return self.currentItem ? self.engine.currentTime : 0;
}

- (NSTimeInterval)duration {
    NSTimeInterval duration = self.currentItem ? self.engine.duration : 0;
    return duration > 0 ? duration : self.currentItem.durationMs / 1000.0;
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
    // YouMod's default playback speed applies to downloads too.
    NSInteger speedIndex = INTFORVAL(AutoSpeedIndex);
    NSArray *speeds = @[@1.0, @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];
    if (speedIndex > 0 && speedIndex < (NSInteger)speeds.count) _rate = [speeds[speedIndex] floatValue];
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
    [self.engine setRate:rate];
    [self updateNowPlaying];
    [self postState];
}

- (void)loadCurrentAndPlay:(BOOL)play {
    // Skip files no engine can play (or that are gone).
    NSUInteger attempts = 0;
    YMDownloadItem *item = nil;
    YMPlaybackRoute route = YMPlaybackRouteNative;
    while (attempts++ < self.order.count) {
        YMDownloadItem *candidate = self.queue[self.order[self.position].unsignedIntegerValue];
        BOOL playable = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate.fileURL.path]) route = YMLocalRouteForURL(candidate.fileURL, &playable);
        if (playable) { item = candidate; break; }
        if (self.position + 1 >= self.order.count) break;
        self.position++;
    }
    if (!item) { [self stop]; return; }
    [self loadItem:item route:route play:play];
}

- (void)loadItem:(YMDownloadItem *)item route:(YMPlaybackRoute)route play:(BOOL)play {
    self.currentItem = item;
    [self switchToEngine:[self engineForRoute:route]];
    NSTimeInterval resume = [[YMDownloadLibrary sharedLibrary] resumePositionForItem:item];
    NSTimeInterval duration = item.durationMs / 1000.0;
    if (resume <= 5 || (duration > 0 && resume >= duration - 5)) resume = 0;
    self.lastSavedPosition = resume;
    [self.engine loadURL:item.fileURL startTime:resume];
    [self updateVideoSuspension];

    if (!self.ticker) {
        __weak typeof(self) weakSelf = self;
        self.ticker = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf periodicTick]; }];
    }
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
    if (!self.currentItem) return;
    YTPlayerViewController *youtube = YouModDownloadGetCurrentPlayer();
    if ([youtube respondsToSelector:@selector(pause)]) [youtube pause];
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:nil];
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    [self.engine play];
    [self engineStateChanged];
}

- (void)pause {
    [self.engine pause];
    [self saveResumePosition];
    [self engineStateChanged];
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
    [self.engine seekToTime:time completion:^{ [weakSelf engineStateChanged]; }];
}

- (void)seekBy:(NSTimeInterval)delta {
    [self seekToTime:self.currentTime + delta];
}

- (void)stop {
    [self saveResumePosition];
    [self.engine stop];
    [self.ticker invalidate];
    self.ticker = nil;
    self.currentItem = nil;
    self.queue = nil;
    self.order = nil;
    self.position = 0;
    [self removeRemoteCommands];
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:YMLocalPlaybackItemDidChangeNotification object:self];
    [self postState];
}

- (void)engineReachedEnd {
    [[YMDownloadLibrary sharedLibrary] setResumePosition:0 forItem:self.currentItem];
    self.lastSavedPosition = 0;
    if (self.repeatMode == YMRepeatModeOne) {
        [self.engine seekToTime:0 completion:nil];
        [self.engine play];
    } else if (self.hasNext) {
        [self next];
    } else {
        [self postState];
    }
}

// AVFoundation sometimes accepts a file it then can't decode; VLC gets a go first.
- (void)engineFailed {
    YMDownloadItem *item = self.currentItem;
    if (item && self.engine.route == YMPlaybackRouteNative && [YMVLCEngine isAvailable]) {
        [self loadItem:item route:YMPlaybackRouteVLC play:YES];
        return;
    }
    YMDownloadShowToast(LOC(@"PLAYBACK_FAILED"), YES);
    [self postState];
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
    if (!self.currentItem) return;
    NSTimeInterval time = self.currentTime;
    NSTimeInterval duration = self.duration;
    // Nearly finished counts as watched.
    if (duration > 0 && time > duration - 10) time = 0;
    if (time < 5) time = 0;
    [[YMDownloadLibrary sharedLibrary] setResumePosition:time forItem:self.currentItem];
    self.lastSavedPosition = time;
}

#pragma mark Video views / background

- (void)registerVideoView:(YMLocalVideoView *)view {
    [self.videoViews addObject:view];
    if (self.engine) [self.engine attachVideoView:view];
}

// In the background only the audio is decoded - unless the video is on screen,
// where Picture in Picture starts automatically and needs it (it may not report
// active yet at this point).
- (void)appDidEnterBackground {
    self.inBackground = YES;
    [self updateVideoSuspension];
}

- (void)appWillEnterForeground {
    self.inBackground = NO;
    [self updateVideoSuspension];
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
    [self.commandTargets addObject:add(center.skipForwardCommand, ^(MPRemoteCommandEvent *e) { [weakSelf seekBy:YMSkipSeconds(ForwardSeconds)]; })];
    [self.commandTargets addObject:add(center.skipBackwardCommand, ^(MPRemoteCommandEvent *e) { [weakSelf seekBy:-YMSkipSeconds(RewindSeconds)]; })];
    [self.commandTargets addObject:add(center.changePlaybackPositionCommand, ^(MPRemoteCommandEvent *e) {
        [weakSelf seekToTime:((MPChangePlaybackPositionCommandEvent *)e).positionTime];
    })];
    // YouMod's lock screen skip settings: a skip button replaces previous/next on
    // the side it is enabled for, with the configured seconds.
    BOOL skipBack = IS_ENABLED(SkipBackwardEnabled), skipForward = IS_ENABLED(SkipForwardEnabled);
    center.skipBackwardCommand.enabled = skipBack;
    center.skipBackwardCommand.preferredIntervals = @[@(YMSkipSeconds(RewindSeconds))];
    center.skipForwardCommand.enabled = skipForward;
    center.skipForwardCommand.preferredIntervals = @[@(YMSkipSeconds(ForwardSeconds))];
    center.previousTrackCommand.enabled = !skipBack;
    center.nextTrackCommand.enabled = !skipForward;
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

#pragma mark - Full player

@interface YMLocalPlayerViewController : UIViewController <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *topBand;
@property (nonatomic, strong) UIView *videoContainer;
@property (nonatomic, strong) YMLocalVideoView *videoView;
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
@property (nonatomic, assign) NSInteger pictureInPictureRoute; // route the controller was built for, -1 none
@property (nonatomic, strong) NSTimer *ticker;
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
// Gestures
@property (nonatomic, strong) UITapGestureRecognizer *doubleTap;
@property (nonatomic, strong) UIPanGestureRecognizer *panGesture;
@property (nonatomic, strong) UILongPressGestureRecognizer *holdGesture;
@property (nonatomic, assign) NSInteger panMode;
@property (nonatomic, assign) double panStartValue;
@property (nonatomic, strong) UILabel *gestureHUD;
@property (nonatomic, strong) UILabel *speedToast;
@property (nonatomic, assign) float holdSavedRate;
@property (nonatomic, assign) BOOL holdLockPending;
@property (nonatomic, assign) CGFloat holdStartY;
@property (nonatomic, assign) NSTimeInterval lastDoubleTapTime;
@property (nonatomic, assign) BOOL lastDoubleTapForward;
@property (nonatomic, assign) NSTimeInterval doubleTapTotal;
// YouMod overlay buttons and speed stepper
@property (nonatomic, copy) NSArray<UIButton *> *overlayButtons;
@property (nonatomic, strong) UIView *speedStepper;
@property (nonatomic, strong) UILabel *stepperLabel;
@property (nonatomic, assign) BOOL showsRemainingTime;
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

    self.videoView = [YMLocalVideoView new];
    self.videoView.videoGravity = AVLayerVideoGravityResizeAspect;
    [playback registerVideoView:self.videoView];
    [self.videoContainer addSubview:self.videoView];
    self.pictureInPictureRoute = -1;

    [self buildControls];
    [self buildSpeedStepper];
    [self rebuildOverlayButtons];
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

    [self installGestures];
    self.showsRemainingTime = IS_ENABLED(AlwaysShowRemaining) && !IS_ENABLED(DisablesShowRemaining);

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
    self.timeLabel.userInteractionEnabled = YES;
    [self.timeLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(timeLabelTapped)]];

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
}

// Picture in Picture follows the engine: the AVPlayerLayer on the native route, the
// sample buffer layer (iOS 15+) on the VLC route.
- (void)rebuildPictureInPictureIfNeeded {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    YMPlaybackRoute route = playback.route;
    if (self.pictureInPicture && self.pictureInPictureRoute == route) return;
    if (self.pictureInPicture.isPictureInPictureActive) return;
    self.pictureInPicture = nil;
    self.pictureInPictureRoute = -1;
    if (![AVPictureInPictureController isPictureInPictureSupported]) return;
    if (route == YMPlaybackRouteNative) {
        self.pictureInPicture = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.videoView.playerLayer];
    } else if (@available(iOS 15.0, *)) {
        AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.videoView.sampleLayer playbackDelegate:self];
        self.pictureInPicture = [[AVPictureInPictureController alloc] initWithContentSource:source];
    }
    if (!self.pictureInPicture) return;
    self.pictureInPictureRoute = route;
    self.pictureInPicture.delegate = self;
    if (@available(iOS 14.2, *)) self.pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = YES;
    playback.pictureInPicture = self.pictureInPicture;
}

#pragma mark Sample buffer PiP (VLC route)

- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing API_AVAILABLE(ios(15.0)) {
    if (playing) [[YMLocalPlayback sharedPlayback] play];
    else [[YMLocalPlayback sharedPlayback] pause];
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller API_AVAILABLE(ios(15.0)) {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    NSTimeInterval duration = playback.duration;
    if (duration <= 0) return CMTimeRangeMake(kCMTimeNegativeInfinity, kCMTimePositiveInfinity);
    // Expressed against the host clock so the PiP scrubber tracks VLC's position.
    NSTimeInterval now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    NSTimeInterval start = now - playback.currentTime;
    return CMTimeRangeMake(CMTimeMakeWithSeconds(start, 600), CMTimeMakeWithSeconds(duration, 600));
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller API_AVAILABLE(ios(15.0)) {
    return ![YMLocalPlayback sharedPlayback].isPlaying;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)newRenderSize API_AVAILABLE(ios(15.0)) {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)skipInterval completionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(15.0)) {
    [[YMLocalPlayback sharedPlayback] seekBy:CMTimeGetSeconds(skipInterval)];
    if (completionHandler) completionHandler();
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
    [self layoutOverlayButtonsWithInsets:inner timeY:timeY];
    // The stepper sits under the transport buttons when there is room for it.
    CGFloat stepperY = CGRectGetMaxY(self.playButton.frame) + 10;
    self.speedStepper.hidden = ![self wantsSpeedStepper] || stepperY + 28 > timeY - 4;
    self.speedStepper.center = CGPointMake(w / 2, stepperY + 14);
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
    BOOL showVideo = item.isVideo && !playback.audioOnly;
    self.artworkBackground.hidden = self.artworkView.hidden = showVideo;
    self.videoView.hidden = !showVideo;
    [self rebuildPictureInPictureIfNeeded];
    self.pipButton.hidden = !item.isVideo || self.pictureInPicture == nil;
    self.fullscreenButton.hidden = !item.isVideo;
    [self rebuildActions];
    [self stateChanged];
}

- (void)stateChanged {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    if (@available(iOS 15.0, *)) {
        if (self.pictureInPictureRoute == YMPlaybackRouteVLC) [self.pictureInPicture invalidatePlaybackState];
    }
    [self.playButton setImage:YMSymbol(playback.isPlaying ? @"pause.fill" : @"play.fill", 34, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    self.nextButton.enabled = playback.hasNext;
    self.nextButton.alpha = playback.hasNext ? 1 : 0.4;

    NSString *rateTitle = [self rateTitle:playback.rate];
    [self.speedButton setTitle:rateTitle forState:UIControlStateNormal];
    NSMutableArray *rates = [NSMutableArray array];
    for (NSNumber *value in YMSpeedOptions()) {
        UIAction *action = [UIAction actionWithTitle:[self rateTitle:value.floatValue] image:nil identifier:nil handler:^(UIAction *a) {
            [YMLocalPlayback sharedPlayback].rate = value.floatValue;
        }];
        if (fabsf(value.floatValue - playback.rate) < 0.01) action.state = UIMenuElementStateOn;
        [rates addObject:action];
    }
    self.speedButton.menu = [UIMenu menuWithTitle:LOC(@"PLAYBACK_SPEED") children:rates];
    self.stepperLabel.text = rateTitle;
    [self refreshOverlayButtons];
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
    NSString *elapsed = self.showsRemainingTime ? [@"-" stringByAppendingString:YMLocalFormatTime(MAX(duration - time, 0))] : YMLocalFormatTime(time);
    NSString *text = [NSString stringWithFormat:@"%@ / %@", elapsed, YMLocalFormatTime(duration)];
    if (IS_ENABLED(ShowExtraTimeRemaining) && duration > 0) {
        // YouMod: when playback ends at the current speed.
        static NSDateFormatter *formatter;
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        }
        formatter.dateFormat = IS_ENABLED(Uses24HoursTime) ? @"HH:mm" : @"h:mm a";
        NSTimeInterval remaining = MAX(duration - time, 0) / MAX(playback.rate, 0.1f);
        text = [text stringByAppendingFormat:@" · %@", [formatter stringFromDate:[NSDate dateWithTimeIntervalSinceNow:remaining]]];
    }
    self.timeLabel.text = text;
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

- (void)playTapped {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    BOOL pausing = playback.isPlaying;
    [playback togglePlayPause];
    // YouMod "copy timestamp on pause".
    if (pausing && IS_ENABLED(CopyWithTimestampOnPause)) [self copyLinkAtCurrentTime];
}

- (void)timeLabelTapped {
    if (IS_ENABLED(DisablesShowRemaining)) return;
    self.showsRemainingTime = !self.showsRemainingTime;
    [self updateTime];
    [self scheduleHide];
}
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

#pragma mark Gestures (YouTube's and YouMod's)

typedef NS_ENUM(NSInteger, YMLocalPanMode) {
    YMLocalPanNone,
    YMLocalPanDismiss,        // drag the page down to the mini player
    YMLocalPanEnterFullscreen,// swipe up on the video
    YMLocalPanExitFullscreen, // swipe down on the video in landscape
    YMLocalPanSeek,           // YouMod "seek on overlay": slide horizontally
    YMLocalPanBrightness,     // YouMod gesture controls, per side
    YMLocalPanVolume,
    YMLocalPanSpeed,
};

- (void)installGestures {
    // Double tap: YouTube's seek (left/right) - off with YouMod's "Disable double tap".
    if (!IS_ENABLED(DisablesDoubleTap)) {
        self.doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoDoubleTapped:)];
        self.doubleTap.numberOfTapsRequired = 2;
        [self.videoContainer addGestureRecognizer:self.doubleTap];
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(videoTapped:)];
    if (self.doubleTap) [tap requireGestureRecognizerToFail:self.doubleTap];
    [self.videoContainer addGestureRecognizer:tap];

    // Two-finger tap to play/pause (YouMod).
    if (IS_ENABLED(PauseTwoFingers)) {
        UITapGestureRecognizer *twoFinger = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerTapped:)];
        twoFinger.numberOfTouchesRequired = 2;
        [self.videoContainer addGestureRecognizer:twoFinger];
        [tap requireGestureRecognizerToFail:twoFinger];
    }

    // Hold for speed: YouTube's 2x, or YouMod's hold-to-speed value.
    if (INTFORVAL(HoldToSpeedIndex) != 0 || !IS_ENABLED(DisablesLongHold)) {
        self.holdGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(holdForSpeed:)];
        self.holdGesture.minimumPressDuration = 0.4;
        self.holdGesture.delegate = self;
        [self.videoContainer addGestureRecognizer:self.holdGesture];
    }

    // Pinch: zoom to fill (YouTube) - off with YouMod's "Disable free zoom".
    if (!IS_ENABLED(DisablesFreeZoom)) {
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
        [self.videoContainer addGestureRecognizer:pinch];
    }

    // One pan for everything vertical/horizontal; the mode is chosen when it begins.
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
    pan.delegate = self;
    pan.maximumNumberOfTouches = 1;
    [self.view addGestureRecognizer:pan];
    self.panGesture = pan;
}

- (CGFloat)gestureAreaFraction {
    switch (INTFORVAL(GestureActivationArea)) {
        case 0: return 0.10; case 2: return 0.20; case 3: return 0.25; case 4: return 0.30;
        case 5: return 0.35; case 6: return 0.40; case 7: return 0.45; case 8: return 0.50;
        default: return 0.15;
    }
}

// YouMod's side action at x (in the video): 0 none, 1 brightness, 2 volume, 3 speed.
- (NSInteger)sideActionAtX:(CGFloat)x width:(CGFloat)width {
    if (!IS_ENABLED(GestureControls) || width <= 0) return 0;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger left = [defaults objectForKey:LeftSideGesture] ? INTFORVAL(LeftSideGesture) : 1;
    NSInteger right = [defaults objectForKey:RightSideGesture] ? INTFORVAL(RightSideGesture) : 2;
    CGFloat area = [self gestureAreaFraction];
    if (x <= width * area) return left;
    if (x >= width * (1 - area)) return right;
    return 0;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (gesture == self.holdGesture) {
        return self.panMode == YMLocalPanNone && [YMLocalPlayback sharedPlayback].isPlaying;
    }
    if (gesture != self.panGesture) return YES;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gesture;
    CGPoint point = [pan locationInView:self.view];
    CGPoint velocity = [pan velocityInView:self.view];
    UIView *hit = [self.view hitTest:point withEvent:nil];
    if ([hit isKindOfClass:UIControl.class] || [self.slider pointInside:[pan locationInView:self.slider] withEvent:nil]) return NO;
    if (self.holdGesture.state == UIGestureRecognizerStateBegan || self.holdGesture.state == UIGestureRecognizerStateChanged) return NO;

    BOOL horizontal = fabs(velocity.x) > fabs(velocity.y);
    BOOL landscape = [self isLandscape];
    CGRect videoFrame = [self.videoContainer convertRect:self.videoContainer.bounds toView:self.view];
    self.panMode = YMLocalPanNone;

    if (CGRectContainsPoint(videoFrame, point)) {
        CGPoint inVideo = [pan locationInView:self.videoContainer];
        if (horizontal) {
            if (IS_ENABLED(SeekOnOverlay)) self.panMode = YMLocalPanSeek;
        } else {
            NSInteger side = [self sideActionAtX:inVideo.x width:self.videoContainer.bounds.size.width];
            if (side == 1) self.panMode = YMLocalPanBrightness;
            else if (side == 2) self.panMode = YMLocalPanVolume;
            else if (side == 3) self.panMode = YMLocalPanSpeed;
            else if (velocity.y < 0) self.panMode = (!landscape && [YMLocalPlayback sharedPlayback].currentItem.isVideo && !isPad()) ? YMLocalPanEnterFullscreen : YMLocalPanNone;
            else self.panMode = landscape ? YMLocalPanExitFullscreen : YMLocalPanDismiss;
        }
    } else if (!landscape && !horizontal && velocity.y > 0) {
        // From the info area only when it is scrolled to the top.
        if (!(CGRectContainsPoint(self.infoScroll.frame, point) && self.infoScroll.contentOffset.y > 0)) self.panMode = YMLocalPanDismiss;
    }
    return self.panMode != YMLocalPanNone;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

- (void)panned:(UIPanGestureRecognizer *)pan {
    switch (self.panMode) {
        case YMLocalPanDismiss: [self dismissPan:pan]; break;
        case YMLocalPanSeek: [self seekPan:pan]; break;
        case YMLocalPanBrightness:
        case YMLocalPanVolume:
        case YMLocalPanSpeed: [self sidePan:pan]; break;
        case YMLocalPanEnterFullscreen:
        case YMLocalPanExitFullscreen:
            if (pan.state == UIGestureRecognizerStateEnded) {
                CGFloat dy = [pan translationInView:self.view].y;
                BOOL enter = self.panMode == YMLocalPanEnterFullscreen;
                if ((enter && dy < -40) || (!enter && dy > 40)) [self toggleFullscreen];
            }
            break;
        default: break;
    }
    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled || pan.state == UIGestureRecognizerStateFailed) {
        self.panMode = YMLocalPanNone;
    }
}

// YouMod "seek on overlay".
- (void)seekPan:(UIPanGestureRecognizer *)pan {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    NSTimeInterval duration = playback.duration;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.panStartValue = playback.currentTime;
        self.scrubbing = YES;
        [self setControlsVisible:YES animated:YES];
    }
    // Like dragging YouTube's scrubber: the video's width spans the whole duration.
    CGFloat width = MAX(self.videoContainer.bounds.size.width, 1);
    NSTimeInterval target = MIN(MAX(self.panStartValue + [pan translationInView:self.view].x / width * duration, 0), MAX(duration - 0.5, 0));
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        if (duration > 0) self.slider.value = target / duration;
        [self updateTime];
        NSTimeInterval delta = target - self.panStartValue;
        [self showHUDWithSymbol:delta >= 0 ? @"forward.fill" : @"backward.fill"
                           text:[NSString stringWithFormat:@" %@ (%@%@)", YMLocalFormatTime(target), delta >= 0 ? @"+" : @"−", YMLocalFormatTime(fabs(delta))]
                       position:1];
    } else {
        if (pan.state == UIGestureRecognizerStateEnded) [playback seekToTime:target];
        self.scrubbing = NO;
        [self hideHUD];
        [self scheduleHide];
    }
}

// YouMod gesture controls: brightness / volume / speed on the sides.
- (void)sidePan:(UIPanGestureRecognizer *)pan {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    static MPVolumeView *volumeView;
    static UISlider *volumeSlider;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(-1000, -1000, 10, 10)];
        for (UIView *view in volumeView.subviews) if ([view isKindOfClass:UISlider.class]) volumeSlider = (UISlider *)view;
    });
    BOOL appVolume = INTFORVAL(VolumeGestureTarget) == 1;
    if (pan.state == UIGestureRecognizerStateBegan) {
        if (self.panMode == YMLocalPanBrightness) self.panStartValue = UIScreen.mainScreen.brightness;
        else if (self.panMode == YMLocalPanVolume) self.panStartValue = appVolume ? playback.volume : AVAudioSession.sharedInstance.outputVolume;
        else self.panStartValue = playback.rate;
        if (!appVolume && !volumeView.superview) [self.view addSubview:volumeView];
        return;
    }
    if (pan.state != UIGestureRecognizerStateChanged) {
        [self hideHUD];
        return;
    }
    CGFloat delta = -[pan translationInView:self.view].y / MAX(self.videoContainer.bounds.size.height, 1);
    NSString *symbol = nil, *text = nil;
    if (self.panMode == YMLocalPanBrightness) {
        CGFloat value = MIN(MAX(self.panStartValue + delta, 0), 1);
        UIScreen.mainScreen.brightness = value;
        symbol = value <= 0.5 ? @"sun.min.fill" : @"sun.max.fill";
        text = [NSString stringWithFormat:@" %d%%", (int)(value * 100)];
    } else if (self.panMode == YMLocalPanVolume) {
        if (appVolume) {
            // App volume: the VLC route boosts up to 200%.
            float value = MIN(MAX(self.panStartValue + delta * playback.maximumVolume, 0), playback.maximumVolume);
            playback.volume = value;
            symbol = value == 0 ? @"speaker.slash.fill" : (value <= 1 ? @"speaker.wave.1.fill" : @"speaker.wave.3.fill");
            text = [NSString stringWithFormat:@" %d%%", (int)lroundf(value * 100)];
        } else {
            float value = MIN(MAX(self.panStartValue + delta, 0), 1);
            volumeSlider.value = value;
            symbol = value == 0 ? @"speaker.slash.fill" : (value <= 0.33 ? @"speaker.wave.1.fill" : (value <= 0.66 ? @"speaker.wave.2.fill" : @"speaker.wave.3.fill"));
            text = [NSString stringWithFormat:@" %d%%", (int)(value * 100)];
        }
    } else {
        // 0.05 steps, like YouMod's speed gesture.
        float value = roundf(MIN(MAX(self.panStartValue + delta * 8, 0.25), YMMaximumRate()) * 20) / 20;
        if (fabsf(value - playback.rate) > 0.001f) playback.rate = value;
        symbol = value < 1 ? @"tortoise.fill" : (value == 1 ? @"speedometer" : @"hare.fill");
        text = [NSString stringWithFormat:@" %.2fx", value];
    }
    [self showHUDWithSymbol:symbol text:text position:-1];
}

// YouMod's gesture HUD (size/position settings honored); position -1 = the setting.
- (void)showHUDWithSymbol:(NSString *)symbol text:(NSString *)text position:(NSInteger)position {
    if (!IS_ENABLED(GestureHUD) && position < 0) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger size = [defaults objectForKey:GestureHUDSize] ? [defaults integerForKey:GestureHUDSize] : 1;
    if (position < 0) position = [defaults objectForKey:GestureHUDPosition] ? [defaults integerForKey:GestureHUDPosition] : 0;
    UILabel *hud = self.gestureHUD;
    if (!hud) {
        hud = [UILabel new];
        hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        hud.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        hud.textAlignment = NSTextAlignmentCenter;
        hud.layer.masksToBounds = YES;
        hud.alpha = 0;
        [self.videoContainer addSubview:hud];
        self.gestureHUD = hud;
    }
    hud.font = [UIFont monospacedDigitSystemFontOfSize:14 + size * 2 weight:UIFontWeightBold];
    NSMutableAttributedString *string = [NSMutableAttributedString new];
    if (symbol) {
        NSTextAttachment *attachment = [NSTextAttachment new];
        UIImage *icon = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:hud.font.pointSize - 1]] imageWithTintColor:hud.textColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        attachment.image = icon;
        attachment.bounds = CGRectMake(0, (hud.font.capHeight - icon.size.height) / 2, icon.size.width, icon.size.height);
        [string appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    }
    [string appendAttributedString:[[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{NSFontAttributeName: hud.font, NSForegroundColorAttributeName: hud.textColor}]];
    hud.attributedText = string;
    CGSize fit = [hud sizeThatFits:CGSizeMake(400, 100)];
    CGFloat height = 30 + size * 4;
    hud.bounds = CGRectMake(0, 0, MAX(fit.width + 28, 74 + size * 10), height);
    hud.layer.cornerRadius = height / 2;
    CGFloat videoHeight = self.videoContainer.bounds.size.height;
    CGFloat y = position == 1 ? videoHeight / 2 : (position == 2 ? videoHeight * 5 / 6 : videoHeight / 6);
    hud.center = CGPointMake(self.videoContainer.bounds.size.width / 2, MAX(y, height / 2 + 4));
    [self.videoContainer bringSubviewToFront:hud];
    [hud.layer removeAllAnimations];
    hud.alpha = 1;
}

- (void)hideHUD {
    [UIView animateWithDuration:0.3 delay:0.4 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ self.gestureHUD.alpha = 0; } completion:nil];
}

// Double tap seek, YouTube style: repeated taps on the same side add up.
- (void)videoDoubleTapped:(UITapGestureRecognizer *)tap {
    CGPoint point = [tap locationInView:self.videoContainer];
    CGFloat width = self.videoContainer.bounds.size.width;
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    if (point.x > width * 0.35 && point.x < width * 0.65) {
        [playback togglePlayPause];
        return;
    }
    BOOL forward = point.x >= width / 2;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - self.lastDoubleTapTime > 1.2 || self.lastDoubleTapForward != forward) self.doubleTapTotal = 0;
    self.lastDoubleTapTime = now;
    self.lastDoubleTapForward = forward;
    NSTimeInterval step = YMDoubleTapSeekSeconds();
    self.doubleTapTotal += step;
    [playback seekBy:forward ? step : -step];
    self.seekFeedback.text = [NSString stringWithFormat:@"%@%ds", forward ? @"+" : @"−", (int)self.doubleTapTotal];
    self.seekFeedback.center = CGPointMake(forward ? width * 0.78 : width * 0.22, self.videoContainer.bounds.size.height / 2);
    [self.seekFeedback.layer removeAllAnimations];
    self.seekFeedback.alpha = 1;
    [UIView animateWithDuration:0.3 delay:0.7 options:UIViewAnimationOptionAllowUserInteraction animations:^{ self.seekFeedback.alpha = 0; } completion:nil];
}

- (void)twoFingerTapped:(UITapGestureRecognizer *)tap {
    [self playTapped];
}

// Hold for speed. With YouMod's "lock speed", dragging down while holding keeps it.
- (void)holdForSpeed:(UILongPressGestureRecognizer *)gesture {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    NSInteger index = INTFORVAL(HoldToSpeedIndex);
    NSArray *speeds = @[@2.0, @0.25, @0.5, @0.75, @1.0, @1.25, @1.5, @1.75, @2.0, @3.0, @4.0, @5.0];
    float speed = index > 0 && index < (NSInteger)speeds.count ? [speeds[index] floatValue] : 2.0f;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.holdSavedRate = playback.rate;
            self.holdLockPending = NO;
            self.holdStartY = [gesture locationInView:self.videoContainer].y;
            playback.rate = speed;
            [self showSpeedToast:speed locked:NO];
            [[UIImpactFeedbackGenerator new] impactOccurred];
            break;
        case UIGestureRecognizerStateChanged: {
            if (!IS_ENABLED(LockSpeed)) break;
            CGFloat dy = [gesture locationInView:self.videoContainer].y - self.holdStartY;
            BOOL pending = self.holdLockPending ? dy > 20 : dy > 40;
            if (pending != self.holdLockPending) {
                self.holdLockPending = pending;
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:pending ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight] impactOccurred];
                [self showSpeedToast:speed locked:pending];
            }
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (!self.holdLockPending) playback.rate = self.holdSavedRate > 0 ? self.holdSavedRate : 1.0f;
            self.holdLockPending = NO;
            [UIView animateWithDuration:0.2 animations:^{ self.speedToast.alpha = 0; }];
            break;
        }
        default:
            break;
    }
}

- (void)showSpeedToast:(float)speed locked:(BOOL)locked {
    if (!self.speedToast) {
        UILabel *toast = [UILabel new];
        toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        toast.textColor = UIColor.whiteColor;
        toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.layer.cornerRadius = 16;
        toast.layer.masksToBounds = YES;
        [self.videoContainer addSubview:toast];
        self.speedToast = toast;
    }
    NSString *symbol = locked ? @"lock.fill" : @"forward.fill";
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%gx ", speed] attributes:@{NSFontAttributeName: self.speedToast.font, NSForegroundColorAttributeName: UIColor.whiteColor}];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = [[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    self.speedToast.attributedText = text;
    CGSize fit = [self.speedToast sizeThatFits:CGSizeMake(200, 32)];
    CGFloat top = [self isLandscape] ? MAX(self.view.safeAreaInsets.top, 12) : 12;
    self.speedToast.frame = CGRectMake((self.videoContainer.bounds.size.width - fit.width - 28) / 2, top, fit.width + 28, 32);
    [self.videoContainer bringSubviewToFront:self.speedToast];
    self.speedToast.alpha = 1;
}

// Pinch out fills the screen (crop), pinch in fits the video back; in portrait a
// pinch out goes full screen first.
- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    if (![self isLandscape]) {
        if (pinch.scale > 1.2 && [YMLocalPlayback sharedPlayback].currentItem.isVideo && !isPad()) [self toggleFullscreen];
        return;
    }
    BOOL fill = pinch.scale > 1.05;
    if (pinch.scale > 0.95 && pinch.scale < 1.05) return;
    self.videoView.videoGravity = fill ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
    [self showHUDWithSymbol:fill ? @"arrow.up.left.and.arrow.down.right" : @"arrow.down.right.and.arrow.up.left" text:fill ? LOC(@"ZOOMED_TO_FILL") : LOC(@"ORIGINAL_SIZE") position:1];
    [self hideHUD];
}

#pragma mark YouMod overlay buttons

// The overlay buttons that make sense for a local file, in the order and with the
// on/off state set in YouMod's overlay button settings. Download, SponsorBlock,
// quality and captions need YouTube's servers and are left out.
- (NSArray<YMOverlayButtonSpec *> *)localOverlaySpecs {
    NSSet *supported = [NSSet setWithArray:@[@"mute.video", @"speed.video", @"share.video", @"loop.video", @"radio.video"]];
    NSMutableArray *specs = [NSMutableArray array];
    for (YMOverlayButtonSpec *spec in YMOrderedOverlayButtons()) {
        if ([supported containsObject:spec.identifier] && YMIsOverlayButtonEnabled(spec.identifier)) [specs addObject:spec];
    }
    return specs;
}

- (UIButton *)overlayButtonForSpec:(YMOverlayButtonSpec *)spec {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    button.layer.cornerRadius = 16;
    button.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    button.accessibilityIdentifier = spec.identifier;
    button.accessibilityLabel = spec.displayName;
    __weak typeof(self) weakSelf = self;
    NSString *identifier = spec.identifier;
    if ([identifier isEqualToString:@"speed.video"]) {
        button.showsMenuAsPrimaryAction = YES;
    } else if ([identifier isEqualToString:@"share.video"]) {
        button.showsMenuAsPrimaryAction = YES;
        [button setImage:YMSymbol(@"arrowshape.turn.up.right", 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    } else {
        [button addAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf overlayButtonTapped:identifier]; }] forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

- (void)rebuildOverlayButtons {
    for (UIButton *button in self.overlayButtons) [button removeFromSuperview];
    NSMutableArray *buttons = [NSMutableArray array];
    for (YMOverlayButtonSpec *spec in [self localOverlaySpecs]) {
        UIButton *button = [self overlayButtonForSpec:spec];
        [self.controls addSubview:button];
        [buttons addObject:button];
    }
    self.overlayButtons = buttons;
    [self refreshOverlayButtons];
}

- (UIButton *)overlayButton:(NSString *)identifier {
    for (UIButton *button in self.overlayButtons) if ([button.accessibilityIdentifier isEqualToString:identifier]) return button;
    return nil;
}

- (void)refreshOverlayButtons {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    YMDownloadItem *item = playback.currentItem;
    UIButton *mute = [self overlayButton:@"mute.video"];
    [mute setImage:YMSymbol(playback.muted ? @"speaker.slash" : @"speaker.wave.2", 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    UIButton *loop = [self overlayButton:@"loop.video"];
    BOOL looping = playback.repeatMode == YMRepeatModeOne;
    [loop setImage:YMSymbol(looping ? @"repeat.1" : @"repeat", 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    loop.tintColor = looping ? UIColor.systemRedColor : UIColor.whiteColor;
    UIButton *radio = [self overlayButton:@"radio.video"];
    [radio setImage:YMSymbol(@"headphones", 14, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    radio.tintColor = playback.audioOnly ? UIColor.systemRedColor : UIColor.whiteColor;
    radio.hidden = !item.isVideo;
    UIButton *speed = [self overlayButton:@"speed.video"];
    [speed setTitle:[self rateTitle:playback.rate] forState:UIControlStateNormal];
    speed.menu = self.speedButton.menu;
    // The tweak's speed button replaces the built-in one.
    self.speedButton.hidden = speed != nil;
    UIButton *share = [self overlayButton:@"share.video"];
    if (share && item) {
        __weak typeof(self) weakSelf = self;
        NSMutableArray *actions = [NSMutableArray arrayWithObject:[UIAction actionWithTitle:LOC(@"SHARE") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) {
            YMDownloadShareFile(item.fileURL, weakSelf);
        }]];
        if (item.videoID.length) {
            [actions addObject:[UIAction actionWithTitle:LOC(@"COPY_LINK_AT_TIME") image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) {
                [weakSelf copyLinkAtCurrentTime];
            }]];
        }
        share.menu = [UIMenu menuWithTitle:@"" children:actions];
    }
    [self.view setNeedsLayout];
}

- (void)overlayButtonTapped:(NSString *)identifier {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    if ([identifier isEqualToString:@"mute.video"]) {
        playback.muted = !playback.muted;
    } else if ([identifier isEqualToString:@"loop.video"]) {
        playback.repeatMode = playback.repeatMode == YMRepeatModeOne ? YMRepeatModeOff : YMRepeatModeOne;
    } else if ([identifier isEqualToString:@"radio.video"]) {
        playback.audioOnly = !playback.audioOnly;
        [self itemChanged];
    }
    [self refreshOverlayButtons];
    [self scheduleHide];
}

- (void)copyLinkAtCurrentTime {
    YMLocalPlayback *playback = [YMLocalPlayback sharedPlayback];
    NSString *videoID = playback.currentItem.videoID;
    if (!videoID.length) return;
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&t=%lds", videoID, (long)playback.currentTime];
    YMDownloadShowToast(LOC(@"COPIED_TO_CLIPBOARD"), NO);
}

// Rows of overlay buttons in YouMod's chosen corner (and offset).
- (void)layoutOverlayButtonsWithInsets:(UIEdgeInsets)inner timeY:(CGFloat)timeY {
    NSMutableArray *visible = [NSMutableArray array];
    for (UIButton *button in self.overlayButtons) if (!button.hidden) [visible addObject:button];
    if (!visible.count) return;
    NSInteger corner = INTFORVAL(OverlayButtonCorner);
    CGFloat offsetX = [NSUserDefaults.standardUserDefaults floatForKey:OverlayButtonOffsetX];
    CGFloat offsetY = [NSUserDefaults.standardUserDefaults floatForKey:OverlayButtonOffsetY];
    BOOL right = corner == 0 || corner == 2;
    BOOL bottom = corner == 2 || corner == 3;
    CGFloat size = 32, gap = 8;
    CGFloat y = bottom ? timeY - size - 6 : inner.top + 46;
    CGFloat x = right ? self.controls.bounds.size.width - inner.right - 4 : inner.left + 4;
    for (UIButton *button in visible) {
        CGFloat width = size;
        if (button.currentTitle.length) width = MAX(size, [button.titleLabel sizeThatFits:CGSizeMake(80, size)].width + 18);
        CGFloat bx = right ? x - width : x;
        button.frame = CGRectMake(bx + offsetX, y + offsetY, width, size);
        x = right ? bx - gap : bx + width + gap;
    }
}

#pragma mark Speed stepper (YouMod "button" speed control)

- (BOOL)wantsSpeedStepper {
    return IS_ENABLED(ShowSpeedSlider) && INTFORVAL(SpeedControlStyle) == 1;
}

- (void)buildSpeedStepper {
    UIView *stepper = [UIView new];
    UIButton *minus = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButton *plus = [UIButton buttonWithType:UIButtonTypeSystem];
    UILabel *label = [UILabel new];
    for (UIButton *button in @[minus, plus]) {
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        button.layer.cornerRadius = 14;
    }
    [minus setImage:YMSymbol(@"minus", 12, UIImageSymbolWeightBold) forState:UIControlStateNormal];
    [plus setImage:YMSymbol(@"plus", 12, UIImageSymbolWeightBold) forState:UIControlStateNormal];
    [minus addAction:[UIAction actionWithHandler:^(UIAction *a) {
        YMLocalPlayback *p = [YMLocalPlayback sharedPlayback];
        p.rate = MAX(0.25f, roundf((p.rate - 0.05f) * 20) / 20);
    }] forControlEvents:UIControlEventTouchUpInside];
    [plus addAction:[UIAction actionWithHandler:^(UIAction *a) {
        YMLocalPlayback *p = [YMLocalPlayback sharedPlayback];
        p.rate = MIN(YMMaximumRate(), roundf((p.rate + 0.05f) * 20) / 20);
    }] forControlEvents:UIControlEventTouchUpInside];
    label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    label.layer.cornerRadius = 12;
    label.layer.masksToBounds = YES;
    minus.frame = CGRectMake(0, 0, 28, 28);
    label.frame = CGRectMake(34, 2, 56, 24);
    plus.frame = CGRectMake(96, 0, 28, 28);
    [stepper addSubview:minus];
    [stepper addSubview:label];
    [stepper addSubview:plus];
    stepper.bounds = CGRectMake(0, 0, 124, 28);
    self.stepperLabel = label;
    self.speedStepper = stepper;
    [self.controls addSubview:stepper];
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
    [self.ticker invalidate];
    self.ticker = nil;
    self.orientationMask = UIInterfaceOrientationMaskAllButUpsideDown;
    self.content.transform = CGAffineTransformIdentity;
    [self.backdrop removeFromSuperview];
    self.backdrop = nil;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    ymPlayerPresented = YES;
    [self.ticker invalidate];
    __weak typeof(self) weakSelf = self;
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { [weakSelf updateTime]; }];
    [self updateFullscreenButton];
    [self rebuildOverlayButtons];
    [self setControlsVisible:YES animated:NO];
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
    BOOL playable = NO;
    YMLocalRouteForURL(item.fileURL, &playable);
    NSString *unsupported = YMLocalUnsupportedFormat(item.fileURL);
    if (playable) {
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
@property (nonatomic, strong) YMLocalVideoView *videoView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressFill;
@property (nonatomic, strong) NSTimer *ticker;
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
        self.videoView = [YMLocalVideoView new];
        self.videoView.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [[YMLocalPlayback sharedPlayback] registerVideoView:self.videoView];
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

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:YMLocalPlaybackItemDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:YMLocalPlaybackStateDidChangeNotification object:nil];
        [self refresh];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self.ticker invalidate];
    self.ticker = nil;
    if (!self.window) return;
    __weak typeof(self) weakSelf = self;
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) { [weakSelf setNeedsLayout]; }];
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
