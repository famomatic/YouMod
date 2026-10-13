// Playback engines for downloaded files (see LocalPlayerEngine.h).
#import "Headers.h"
#import "LocalPlayerEngine.h"
#import <dlfcn.h>
#import <CoreVideo/CoreVideo.h>

#pragma mark - Video view

@interface YMLocalVideoView ()
@property (nonatomic, strong, readwrite) AVPlayerLayer *playerLayer;
@property (nonatomic, strong, readwrite) AVSampleBufferDisplayLayer *sampleLayer;
@end

@implementation YMLocalVideoView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        _playerLayer = [AVPlayerLayer new];
        _sampleLayer = [AVSampleBufferDisplayLayer new];
        _sampleLayer.hidden = YES;
        [self.layer addSublayer:_playerLayer];
        [self.layer addSublayer:_sampleLayer];
        self.videoGravity = AVLayerVideoGravityResizeAspect;
    }
    return self;
}

- (void)setVideoGravity:(AVLayerVideoGravity)videoGravity {
    _videoGravity = [videoGravity copy];
    self.playerLayer.videoGravity = videoGravity;
    self.sampleLayer.videoGravity = videoGravity;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.playerLayer.frame = self.bounds;
    self.sampleLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)showRoute:(YMPlaybackRoute)route {
    BOOL vlc = route == YMPlaybackRouteVLC;
    self.playerLayer.hidden = vlc;
    self.sampleLayer.hidden = !vlc;
    if (vlc) self.playerLayer.player = nil;
    else [self.sampleLayer flushAndRemoveImage];
}

@end

#pragma mark - Native route (AVPlayer)

@interface YMNativeEngine ()
@property (nonatomic, strong, readwrite) AVPlayer *player;
@property (nonatomic, strong) NSHashTable<YMLocalVideoView *> *views;
@property (nonatomic, assign) BOOL videoSuspended;
@property (nonatomic, assign) float rate;
@end

@implementation YMNativeEngine
@synthesize stateHandler = _stateHandler, endHandler = _endHandler, failureHandler = _failureHandler;

- (instancetype)init {
    if ((self = [super init])) {
        _player = [AVPlayer new];
        _player.allowsExternalPlayback = YES;
        _player.automaticallyWaitsToMinimizeStalling = NO;
        _views = [NSHashTable weakObjectsHashTable];
        _rate = 1.0f;
        [_player addObserver:self forKeyPath:@"timeControlStatus" options:0 context:NULL];
        [_player addObserver:self forKeyPath:@"currentItem.duration" options:0 context:NULL];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(itemDidEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(itemFailed:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    }
    return self;
}

- (YMPlaybackRoute)route { return YMPlaybackRouteNative; }

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
            if (self.failureHandler) self.failureHandler();
            return;
        }
        if (self.stateHandler) self.stateHandler();
    });
}

- (void)itemDidEnd:(NSNotification *)note {
    if (note.object != self.player.currentItem) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.endHandler) self.endHandler(); });
}

- (void)itemFailed:(NSNotification *)note {
    if (note.object != self.player.currentItem) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.failureHandler) self.failureHandler(); });
}

- (BOOL)isPlaying {
    return self.player.currentItem && self.player.timeControlStatus != AVPlayerTimeControlStatusPaused;
}

- (NSTimeInterval)currentTime {
    NSTimeInterval time = CMTimeGetSeconds(self.player.currentTime);
    return isfinite(time) ? MAX(time, 0) : 0;
}

- (NSTimeInterval)duration {
    NSTimeInterval duration = CMTimeGetSeconds(self.player.currentItem.duration);
    return isfinite(duration) && duration > 0 ? duration : 0;
}

- (void)loadURL:(NSURL *)url startTime:(NSTimeInterval)startTime {
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    [self.player replaceCurrentItemWithPlayerItem:item];
    if (startTime > 0) [self.player seekToTime:CMTimeMakeWithSeconds(startTime, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    [self reattachViews];
}

- (void)play {
    NSTimeInterval duration = self.duration;
    if (duration > 0 && self.currentTime >= duration - 0.3) [self.player seekToTime:kCMTimeZero];
    [self.player playImmediatelyAtRate:self.rate];
}

- (void)pause { [self.player pause]; }

- (void)stop {
    [self.player pause];
    [self.player replaceCurrentItemWithPlayerItem:nil];
}

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(void))completion {
    [self.player seekToTime:CMTimeMakeWithSeconds(time, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    }];
}

- (void)setRate:(float)rate {
    _rate = rate;
    if (self.isPlaying) self.player.rate = rate;
}

- (void)attachVideoView:(YMLocalVideoView *)view {
    [self.views addObject:view];
    [view showRoute:YMPlaybackRouteNative];
    view.playerLayer.player = self.videoSuspended ? nil : self.player;
}

- (void)reattachViews {
    for (YMLocalVideoView *view in self.views) {
        [view showRoute:YMPlaybackRouteNative];
        view.playerLayer.player = self.videoSuspended ? nil : self.player;
    }
}

// An AVPlayer whose layer is on screen is paused by iOS in the background;
// detaching the layers keeps the audio going.
- (void)setVideoSuspended:(BOOL)suspended {
    _videoSuspended = suspended;
    [self reattachViews];
}

@end

#pragma mark - VLC route (libvlc)

typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef struct libvlc_event_manager_t libvlc_event_manager_t;
typedef struct { int type; void *p_obj; } ym_libvlc_event_t; // only the header is read

enum {
    YMVLCEventPlaying = 0x100 + 4,
    YMVLCEventPaused = 0x100 + 5,
    YMVLCEventStopped = 0x100 + 6,
    YMVLCEventEndReached = 0x100 + 9,
    YMVLCEventError = 0x100 + 10,
    YMVLCEventLengthChanged = 0x100 + 17,
    YMVLCEventBuffering = 0x100 + 3,
};

enum { YMVLCStateEnded = 6, YMVLCStateError = 7, YMVLCStatePlaying = 3, YMVLCStateOpening = 1, YMVLCStateBuffering = 2 };

static libvlc_instance_t *(*vlc_new)(int, const char *const *);
static libvlc_media_t *(*vlc_media_new_path)(libvlc_instance_t *, const char *);
static void (*vlc_media_add_option)(libvlc_media_t *, const char *);
static void (*vlc_media_release)(libvlc_media_t *);
static libvlc_media_player_t *(*vlc_player_new)(libvlc_instance_t *);
static void (*vlc_player_set_media)(libvlc_media_player_t *, libvlc_media_t *);
static int (*vlc_player_play)(libvlc_media_player_t *);
static void (*vlc_player_set_pause)(libvlc_media_player_t *, int);
static void (*vlc_player_stop)(libvlc_media_player_t *);
static int64_t (*vlc_player_get_time)(libvlc_media_player_t *);
static void (*vlc_player_set_time)(libvlc_media_player_t *, int64_t);
static int64_t (*vlc_player_get_length)(libvlc_media_player_t *);
static int (*vlc_player_set_rate)(libvlc_media_player_t *, float);
static int (*vlc_player_get_state)(libvlc_media_player_t *);
static libvlc_event_manager_t *(*vlc_player_event_manager)(libvlc_media_player_t *);
static int (*vlc_event_attach)(libvlc_event_manager_t *, int, void (*)(const ym_libvlc_event_t *, void *), void *);
static int (*vlc_video_get_track)(libvlc_media_player_t *);
static int (*vlc_video_set_track)(libvlc_media_player_t *, int);
static void (*vlc_video_set_callbacks)(libvlc_media_player_t *, void *(*)(void *, void **), void (*)(void *, void *, void *const *), void (*)(void *, void *), void *);
static void (*vlc_video_set_format_callbacks)(libvlc_media_player_t *, unsigned (*)(void **, char *, unsigned *, unsigned *, unsigned *, unsigned *), void (*)(void *));

static NSMutableArray<NSString *> *YMVLCLog(void) {
    static NSMutableArray *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [NSMutableArray array]; });
    return log;
}

static void YMVLCNote(NSString *line) {
    NSMutableArray *log = YMVLCLog();
    @synchronized(log) { [log addObject:line]; }
}

static NSArray<NSString *> *YMVLCSearchPaths(void) {
    NSMutableArray *paths = [NSMutableArray array];
    NSString *suffix = @"MobileVLCKit.framework/MobileVLCKit";
    if (NSBundle.mainBundle.privateFrameworksPath) [paths addObject:[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:suffix]];
    if (NSBundle.mainBundle.resourcePath) [paths addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"YouMod.bundle/Frameworks" stringByAppendingPathComponent:suffix]]];
    [paths addObject:jbroot([@"/Library/Application Support/YouMod.bundle/Frameworks" stringByAppendingPathComponent:suffix])];
    return paths;
}

static libvlc_instance_t *ymVLCInstance;

static BOOL YMVLCLoad(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = NULL;
        for (NSString *path in YMVLCSearchPaths()) {
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
            handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            YMVLCNote([NSString stringWithFormat:@"%@ %@", handle ? @"loaded" : @"failed", path]);
            if (!handle) YMVLCNote([NSString stringWithFormat:@"dlerror: %s", dlerror() ?: "?"]);
            if (handle) break;
        }
        if (!handle) { YMVLCNote(@"MobileVLCKit not found"); return; }
#define YM_VLC_SYM(var, name) var = dlsym(handle, name); if (!var) { YMVLCNote(@"missing " @name); return; }
        YM_VLC_SYM(vlc_new, "libvlc_new");
        YM_VLC_SYM(vlc_media_new_path, "libvlc_media_new_path");
        YM_VLC_SYM(vlc_media_add_option, "libvlc_media_add_option");
        YM_VLC_SYM(vlc_media_release, "libvlc_media_release");
        YM_VLC_SYM(vlc_player_new, "libvlc_media_player_new");
        YM_VLC_SYM(vlc_player_set_media, "libvlc_media_player_set_media");
        YM_VLC_SYM(vlc_player_play, "libvlc_media_player_play");
        YM_VLC_SYM(vlc_player_set_pause, "libvlc_media_player_set_pause");
        YM_VLC_SYM(vlc_player_stop, "libvlc_media_player_stop");
        YM_VLC_SYM(vlc_player_get_time, "libvlc_media_player_get_time");
        YM_VLC_SYM(vlc_player_set_time, "libvlc_media_player_set_time");
        YM_VLC_SYM(vlc_player_get_length, "libvlc_media_player_get_length");
        YM_VLC_SYM(vlc_player_set_rate, "libvlc_media_player_set_rate");
        YM_VLC_SYM(vlc_player_get_state, "libvlc_media_player_get_state");
        YM_VLC_SYM(vlc_player_event_manager, "libvlc_media_player_event_manager");
        YM_VLC_SYM(vlc_event_attach, "libvlc_event_attach");
        YM_VLC_SYM(vlc_video_get_track, "libvlc_video_get_track");
        YM_VLC_SYM(vlc_video_set_track, "libvlc_video_set_track");
        YM_VLC_SYM(vlc_video_set_callbacks, "libvlc_video_set_callbacks");
        YM_VLC_SYM(vlc_video_set_format_callbacks, "libvlc_video_set_format_callbacks");
#undef YM_VLC_SYM
        const char *args[] = {
            "--no-video-title-show", "--no-osd", "--no-snapshot-preview", "--no-stats",
            "--audio-time-stretch",          // keep the pitch at other speeds
            "--avcodec-threads=0",           // software decoding on every core
            "--avcodec-skiploopfilter=0",
            "--no-sub-autodetect-file",
        };
        ymVLCInstance = vlc_new((int)(sizeof(args) / sizeof(args[0])), args);
        loaded = ymVLCInstance != NULL;
        YMVLCNote(loaded ? @"libvlc ready" : @"libvlc_new failed");
    });
    return loaded;
}

NSString *YMVLCDiagnostics(void) {
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"VLC ready: %@", ymVLCInstance ? @"yes" : @"no"]];
    for (NSString *path in YMVLCSearchPaths()) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", [NSFileManager.defaultManager fileExistsAtPath:path] ? @"found" : @"absent", path]];
    }
    NSMutableArray *log = YMVLCLog();
    @synchronized(log) { [lines addObjectsFromArray:log]; }
    return [lines componentsJoinedByString:@"\n"];
}

// One decoded picture handed out by the lock callback: VLC writes the frame into
// the locked pixel buffer, display enqueues it, unlock releases it.
typedef struct {
    CVPixelBufferRef buffer;
    BOOL locked;
} YMVLCPicture;

@interface YMVLCEngine ()
@property (nonatomic, assign) libvlc_media_player_t *mediaPlayer;
@property (nonatomic, strong) NSHashTable<YMLocalVideoView *> *views;
@property (nonatomic, strong) NSArray<AVSampleBufferDisplayLayer *> *layerSnapshot; // read on the vout thread
@property (nonatomic, assign) CVPixelBufferPoolRef pool;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDescription;
@property (nonatomic, assign) unsigned frameWidth;
@property (nonatomic, assign) unsigned frameHeight;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) BOOL wantsPlay;
@property (nonatomic, assign) BOOL ended;
@property (nonatomic, assign) int savedVideoTrack;
@property (nonatomic, assign) BOOL videoSuspended;
@property (nonatomic, assign) float rate;
@property (nonatomic, assign) NSTimeInterval pendingStart;
@property (nonatomic, strong) NSURL *url;
@end

static void YMVLCEventCallback(const ym_libvlc_event_t *event, void *data);
static unsigned YMVLCFormatSetup(void **opaque, char *chroma, unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines);
static void YMVLCFormatCleanup(void *opaque);
static void *YMVLCLock(void *opaque, void **planes);
static void YMVLCUnlock(void *opaque, void *picture, void *const *planes);
static void YMVLCDisplay(void *opaque, void *picture);

@implementation YMVLCEngine
@synthesize stateHandler = _stateHandler, endHandler = _endHandler, failureHandler = _failureHandler;

+ (BOOL)isAvailable {
    return YMVLCLoad();
}

- (instancetype)init {
    if ((self = [super init])) {
        _views = [NSHashTable weakObjectsHashTable];
        _layerSnapshot = @[];
        _rate = 1.0f;
        _savedVideoTrack = -2;
    }
    return self;
}

- (YMPlaybackRoute)route { return YMPlaybackRouteVLC; }

- (libvlc_media_player_t *)ensurePlayer {
    if (self.mediaPlayer || !YMVLCLoad()) return self.mediaPlayer;
    libvlc_media_player_t *player = vlc_player_new(ymVLCInstance);
    if (!player) return NULL;
    void *opaque = (__bridge void *)self; // the engine lives as long as the playback singleton
    vlc_video_set_callbacks(player, YMVLCLock, YMVLCUnlock, YMVLCDisplay, opaque);
    vlc_video_set_format_callbacks(player, YMVLCFormatSetup, YMVLCFormatCleanup);
    libvlc_event_manager_t *events = vlc_player_event_manager(player);
    const int types[] = {YMVLCEventPlaying, YMVLCEventPaused, YMVLCEventStopped, YMVLCEventEndReached, YMVLCEventError, YMVLCEventLengthChanged, YMVLCEventBuffering};
    for (size_t i = 0; i < sizeof(types) / sizeof(types[0]); i++) vlc_event_attach(events, types[i], YMVLCEventCallback, opaque);
    self.mediaPlayer = player;
    return player;
}

- (void)handleEvent:(int)type {
    switch (type) {
        case YMVLCEventPlaying:
            self.paused = NO;
            self.ended = NO;
            if (self.pendingStart > 0) {
                vlc_player_set_time(self.mediaPlayer, (int64_t)(self.pendingStart * 1000));
                self.pendingStart = 0;
            }
            if (fabsf(self.rate - 1.0f) > 0.01f) vlc_player_set_rate(self.mediaPlayer, self.rate);
            if (self.videoSuspended) [self applyVideoSuspension];
            break;
        case YMVLCEventPaused:
            self.paused = YES;
            break;
        case YMVLCEventEndReached:
            self.ended = YES;
            self.wantsPlay = NO;
            if (self.endHandler) self.endHandler();
            break;
        case YMVLCEventError:
            self.wantsPlay = NO;
            if (self.failureHandler) self.failureHandler();
            break;
        default:
            break;
    }
    if (self.stateHandler) self.stateHandler();
}

- (BOOL)isPlaying {
    if (!self.mediaPlayer || !self.url) return NO;
    int state = vlc_player_get_state(self.mediaPlayer);
    if (state == YMVLCStatePlaying) return YES;
    return self.wantsPlay && (state == YMVLCStateOpening || state == YMVLCStateBuffering);
}

- (NSTimeInterval)currentTime {
    if (!self.mediaPlayer || !self.url) return 0;
    if (self.pendingStart > 0) return self.pendingStart;
    if (self.ended) return self.duration;
    int64_t time = vlc_player_get_time(self.mediaPlayer);
    return time > 0 ? time / 1000.0 : 0;
}

- (NSTimeInterval)duration {
    if (!self.mediaPlayer || !self.url) return 0;
    int64_t length = vlc_player_get_length(self.mediaPlayer);
    return length > 0 ? length / 1000.0 : 0;
}

- (void)loadURL:(NSURL *)url startTime:(NSTimeInterval)startTime {
    libvlc_media_player_t *player = [self ensurePlayer];
    if (!player) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.failureHandler) self.failureHandler(); });
        return;
    }
    vlc_player_stop(player);
    self.url = url;
    self.ended = NO;
    self.paused = NO;
    self.wantsPlay = NO;
    self.pendingStart = startTime;
    libvlc_media_t *media = vlc_media_new_path(ymVLCInstance, url.path.fileSystemRepresentation);
    if (!media) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (self.failureHandler) self.failureHandler(); });
        return;
    }
    vlc_player_set_media(player, media);
    vlc_media_release(media);
    for (YMLocalVideoView *view in self.views) [view showRoute:YMPlaybackRouteVLC];
}

- (void)play {
    if (!self.mediaPlayer || !self.url) return;
    self.wantsPlay = YES;
    int state = vlc_player_get_state(self.mediaPlayer);
    if (state == YMVLCStateEnded || state == YMVLCStateError) {
        // A finished player has to be restarted from the beginning.
        vlc_player_stop(self.mediaPlayer);
        self.ended = NO;
        vlc_player_play(self.mediaPlayer);
    } else if (self.paused) {
        vlc_player_set_pause(self.mediaPlayer, 0);
    } else {
        vlc_player_play(self.mediaPlayer);
    }
    if (self.stateHandler) self.stateHandler();
}

- (void)pause {
    if (!self.mediaPlayer) return;
    self.wantsPlay = NO;
    vlc_player_set_pause(self.mediaPlayer, 1);
    if (self.stateHandler) self.stateHandler();
}

- (void)stop {
    self.wantsPlay = NO;
    self.url = nil;
    if (self.mediaPlayer) vlc_player_stop(self.mediaPlayer);
    for (YMLocalVideoView *view in self.views) [view.sampleLayer flushAndRemoveImage];
}

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(void))completion {
    if (!self.mediaPlayer) return;
    int state = vlc_player_get_state(self.mediaPlayer);
    if (state == YMVLCStateEnded) {
        // Seeking needs a running input; restart paused at the target.
        self.pendingStart = time;
        vlc_player_stop(self.mediaPlayer);
        self.ended = NO;
        vlc_player_play(self.mediaPlayer);
        if (!self.wantsPlay) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!self.wantsPlay) vlc_player_set_pause(self.mediaPlayer, 1);
        });
    } else if (state == YMVLCStateOpening || state == YMVLCStateBuffering || state == 0) {
        self.pendingStart = time;
    } else {
        vlc_player_set_time(self.mediaPlayer, (int64_t)(time * 1000));
    }
    if (completion) dispatch_async(dispatch_get_main_queue(), completion);
}

- (void)setRate:(float)rate {
    _rate = rate;
    if (self.mediaPlayer) vlc_player_set_rate(self.mediaPlayer, rate);
}

- (void)attachVideoView:(YMLocalVideoView *)view {
    [self.views addObject:view];
    [view showRoute:YMPlaybackRouteVLC];
    [self refreshLayerSnapshot];
}

- (void)refreshLayerSnapshot {
    NSMutableArray *layers = [NSMutableArray array];
    for (YMLocalVideoView *view in self.views) [layers addObject:view.sampleLayer];
    @synchronized(self) { self.layerSnapshot = layers; }
}

// Without Picture in Picture nobody sees the video in the background, so the video
// track is turned off there and only the audio is decoded.
- (void)setVideoSuspended:(BOOL)suspended {
    if (_videoSuspended == suspended) return;
    _videoSuspended = suspended;
    [self applyVideoSuspension];
}

- (void)applyVideoSuspension {
    if (!self.mediaPlayer || !self.url) return;
    if (self.videoSuspended) {
        int track = vlc_video_get_track(self.mediaPlayer);
        if (track >= 0) {
            self.savedVideoTrack = track;
            vlc_video_set_track(self.mediaPlayer, -1);
        }
    } else if (self.savedVideoTrack >= 0) {
        vlc_video_set_track(self.mediaPlayer, self.savedVideoTrack);
        self.savedVideoTrack = -2;
    }
}

#pragma mark Video output (vout thread)

- (unsigned)setupFormatWithChroma:(char *)chroma width:(unsigned *)width height:(unsigned *)height pitches:(unsigned *)pitches lines:(unsigned *)lines {
    // NV12 ("420v") is what AVSampleBufferDisplayLayer takes without conversion;
    // VLC converts whatever the decoder produces (I420, 10-bit, VideoToolbox) to it.
    memcpy(chroma, "NV12", 4);
    unsigned w = *width, h = *height;
    if (w == 0 || h == 0) return 0;
    [self releasePool];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @(64),
    };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolMinimumBufferCountKey: @4}, (__bridge CFDictionaryRef)attributes, &pool) != kCVReturnSuccess) return 0;
    CVPixelBufferRef probe = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &probe) != kCVReturnSuccess) {
        CVPixelBufferPoolRelease(pool);
        return 0;
    }
    pitches[0] = (unsigned)CVPixelBufferGetBytesPerRowOfPlane(probe, 0);
    pitches[1] = (unsigned)CVPixelBufferGetBytesPerRowOfPlane(probe, 1);
    lines[0] = (unsigned)CVPixelBufferGetHeightOfPlane(probe, 0);
    lines[1] = (unsigned)CVPixelBufferGetHeightOfPlane(probe, 1);
    CMVideoFormatDescriptionRef description = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, probe, &description);
    CVPixelBufferRelease(probe);
    @synchronized(self) {
        self.pool = pool;
        self.formatDescription = description;
        self.frameWidth = w;
        self.frameHeight = h;
    }
    return 4;
}

- (void)releasePool {
    @synchronized(self) {
        if (_pool) CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        if (_formatDescription) CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

- (void *)lockPicture:(void **)planes {
    YMVLCPicture *picture = calloc(1, sizeof(YMVLCPicture));
    CVPixelBufferRef buffer = NULL;
    @synchronized(self) {
        if (_pool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &buffer);
    }
    if (!buffer) {
        // Never hand VLC a NULL plane: give it scratch memory and drop the frame.
        static uint8_t *scratch;
        static size_t scratchSize;
        size_t needed = (size_t)self.frameWidth * self.frameHeight * 2 + 4096;
        if (scratchSize < needed) { free(scratch); scratch = malloc(needed); scratchSize = needed; }
        planes[0] = scratch;
        planes[1] = scratch + (size_t)self.frameWidth * self.frameHeight;
        return picture;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    planes[0] = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    planes[1] = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    picture->buffer = buffer;
    picture->locked = YES;
    return picture;
}

- (void)displayPicture:(YMVLCPicture *)picture {
    CVPixelBufferRef buffer = picture->buffer;
    if (!buffer) return;
    if (picture->locked) {
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        picture->locked = NO;
    }
    CMVideoFormatDescriptionRef description = NULL;
    NSArray<AVSampleBufferDisplayLayer *> *layers;
    @synchronized(self) {
        description = _formatDescription ? (CMVideoFormatDescriptionRef)CFRetain(_formatDescription) : NULL;
        layers = self.layerSnapshot;
    }
    if (!description) return;
    // BT.709 for HD, BT.601 below - VLC's NV12 carries no tag.
    CFStringRef matrix = self.frameHeight >= 720 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, self.frameHeight >= 720 ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_SMPTE_C, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);

    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, description, &timing, &sample);
    CFRelease(description);
    if (status != noErr || !sample) return;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (AVSampleBufferDisplayLayer *layer in layers) {
            if (layer.hidden) continue;
            if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
            [layer enqueueSampleBuffer:sample];
        }
        CFRelease(sample);
    });
}

- (void)unlockPicture:(YMVLCPicture *)picture {
    if (picture->buffer) {
        if (picture->locked) CVPixelBufferUnlockBaseAddress(picture->buffer, 0);
        CVPixelBufferRelease(picture->buffer);
    }
    free(picture);
}

@end

static void YMVLCEventCallback(const ym_libvlc_event_t *event, void *data) {
    int type = event->type;
    YMVLCEngine *engine = (__bridge YMVLCEngine *)data;
    dispatch_async(dispatch_get_main_queue(), ^{ [engine handleEvent:type]; });
}

static unsigned YMVLCFormatSetup(void **opaque, char *chroma, unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines) {
    YMVLCEngine *engine = (__bridge YMVLCEngine *)*opaque;
    return [engine setupFormatWithChroma:chroma width:width height:height pitches:pitches lines:lines];
}

static void YMVLCFormatCleanup(void *opaque) {
    [(__bridge YMVLCEngine *)opaque releasePool];
}

static void *YMVLCLock(void *opaque, void **planes) {
    return [(__bridge YMVLCEngine *)opaque lockPicture:planes];
}

static void YMVLCUnlock(void *opaque, void *picture, void *const *planes) {
    [(__bridge YMVLCEngine *)opaque unlockPicture:(YMVLCPicture *)picture];
}

static void YMVLCDisplay(void *opaque, void *picture) {
    [(__bridge YMVLCEngine *)opaque displayPicture:(YMVLCPicture *)picture];
}
