#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

// Player for finished downloads: a YouTube-style watch page (video, title, channel,
// actions - no comments or related videos), a mini player bar shown at the bottom
// of the Downloads screen, lock screen / Control Center controls, background audio
// and Picture in Picture. One shared playback engine drives all of them.

@class YMDownloadItem;

// Posted on the main queue when the current item changes (also when playback stops).
extern NSString *const YMLocalPlaybackItemDidChangeNotification;
// Posted on the main queue when play/pause, rate, repeat or shuffle change.
extern NSString *const YMLocalPlaybackStateDidChangeNotification;

typedef NS_ENUM(NSInteger, YMRepeatMode) {
    YMRepeatModeOff,
    YMRepeatModeAll,
    YMRepeatModeOne,
};

@interface YMLocalPlayback : NSObject
+ (instancetype)sharedPlayback;
@property (nonatomic, readonly) AVPlayer *player;
@property (nonatomic, readonly) YMDownloadItem *currentItem;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) BOOL hasNext;
@property (nonatomic, assign) YMRepeatMode repeatMode;
@property (nonatomic, assign) BOOL shuffle;
@property (nonatomic, assign) float rate;
- (void)playItems:(NSArray<YMDownloadItem *> *)items startAtIndex:(NSUInteger)index;
- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)next;
- (void)previous;
- (void)stop;
- (void)seekToTime:(NSTimeInterval)time;
- (void)seekBy:(NSTimeInterval)delta;
// Layers showing the video are detached while the app is in the background so iOS
// keeps the audio playing (unless Picture in Picture is running).
- (void)registerPlayerLayer:(AVPlayerLayer *)layer;
- (UIImage *)artworkForItem:(YMDownloadItem *)item;
@end

// Compact bar for the bottom of the Downloads screen: thumbnail/video, title,
// play/pause and close. Tapping it (or swiping up) calls openHandler.
@interface YMLocalMiniPlayerBar : UIView
@property (nonatomic, copy) void (^openHandler)(void);
@end
extern CGFloat YMLocalMiniPlayerBarHeight(void);

// Plays items[index] (the rest of `items` is the queue) and shows the player. Files
// iOS can't decode (VP9, MKV/WebM, Opus on older iOS) are offered a one-time
// conversion with FFmpeg first.
extern void YMLocalPlayerOpen(UIViewController *presenter, NSArray<YMDownloadItem *> *items, NSUInteger index);
// Shows the full player for the current item.
extern void YMLocalPlayerPresent(UIViewController *presenter);
extern NSString *YMLocalFormatTime(NSTimeInterval seconds);
