#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// Playback engines behind YMLocalPlayback, after AetherEngine's design: files
// AVFoundation can decode take the native route (AVPlayer - hardware decoding,
// lowest power, system PiP); everything else (VP9, AV1 without a hardware decoder,
// MKV/WebM, Opus/Vorbis, ...) takes the VLC route: libvlc from MobileVLCKit,
// dlopen'd on first use, decodes and its frames are drawn into an
// AVSampleBufferDisplayLayer - so video views, the mini bar and Picture in Picture
// work the same on both routes.

typedef NS_ENUM(NSInteger, YMPlaybackRoute) {
    YMPlaybackRouteNative,
    YMPlaybackRouteVLC,
};

// Hosts the video of whichever engine is active: an AVPlayerLayer for the native
// route, an AVSampleBufferDisplayLayer for the VLC route.
@interface YMLocalVideoView : UIView
@property (nonatomic, readonly) AVPlayerLayer *playerLayer;
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *sampleLayer;
@property (nonatomic, copy) AVLayerVideoGravity videoGravity;
- (void)showRoute:(YMPlaybackRoute)route;
@end

@protocol YMPlaybackEngine <NSObject>
@property (nonatomic, copy) void (^stateHandler)(void);   // play/pause/buffering/length changes (main queue)
@property (nonatomic, copy) void (^endHandler)(void);     // reached the end (main queue)
@property (nonatomic, copy) void (^failureHandler)(void); // could not play (main queue)
@property (nonatomic, readonly) YMPlaybackRoute route;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;    // 0 while unknown
- (void)loadURL:(NSURL *)url startTime:(NSTimeInterval)startTime;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(void))completion;
- (void)setRate:(float)rate;
// 1.0 = 100%. The VLC route can boost up to 2.0; AVPlayer stops at 1.0.
- (void)setVolume:(float)volume;
- (void)setMuted:(BOOL)muted;
@property (nonatomic, readonly) float maximumVolume;
- (void)attachVideoView:(YMLocalVideoView *)view;
// In the background without Picture in Picture only the audio keeps playing.
- (void)setVideoSuspended:(BOOL)suspended;
@end

@interface YMNativeEngine : NSObject <YMPlaybackEngine>
@property (nonatomic, readonly) AVPlayer *player;
@end

@interface YMVLCEngine : NSObject <YMPlaybackEngine>
+ (BOOL)isAvailable; // MobileVLCKit is installed and loads
@end

extern NSString *YMVLCDiagnostics(void);
