#import <UIKit/UIKit.h>

// Download queue (implemented in Download.x). Jobs run one at a time; finished
// files move to YMDownloadLibrary. Posted on the main queue whenever a job is
// added, starts, makes progress, fails or leaves the queue:
extern NSString *const YMDownloadQueueDidChangeNotification;

@class YouModMediaFormat;

typedef NS_ENUM(NSInteger, YMDownloadJobState) {
    YMDownloadJobStateQueued,
    YMDownloadJobStateRunning,
    YMDownloadJobStateFailed,
};

@interface YMDownloadJob : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *fileName;
@property (nonatomic, copy) NSString *formatSummary;
@property (nonatomic, strong) NSURL *thumbnailURL;
@property (nonatomic, strong) YouModMediaFormat *videoFormat; // nil for audio-only
@property (nonatomic, strong) YouModMediaFormat *audioFormat;
@property (nonatomic, assign) NSInteger audioOutput;
@property (nonatomic, assign) unsigned long long durationMs;
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, assign) YMDownloadJobState state;
@property (nonatomic, assign) float progress;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSString *errorMessage;
@property (nonatomic, readonly) BOOL isVideo;
@end

@interface YMDownloadQueue : NSObject
+ (instancetype)sharedQueue;
@property (nonatomic, readonly) NSArray<YMDownloadJob *> *jobs; // running, queued and failed
- (void)enqueue:(YMDownloadJob *)job;
- (void)cancelJob:(YMDownloadJob *)job;
- (void)retryJob:(YMDownloadJob *)job;
- (void)removeJob:(YMDownloadJob *)job;
- (void)coordinatorReportedProgress:(float)progress status:(NSString *)status;
- (void)coordinatorFinishedWithFileURL:(NSURL *)fileURL isVideo:(BOOL)isVideo presenter:(UIViewController *)presenter;
- (void)coordinatorFailedWithMessage:(NSString *)message;
- (void)coordinatorCancelled;
@end

// Helpers shared with the Downloads screen.
extern void YMDownloadShareFile(NSURL *fileURL, UIViewController *presenter);
extern void YMDownloadSaveVideoToPhotos(NSURL *fileURL, UIViewController *presenter);
extern void YMDownloadShowToast(NSString *message, BOOL error);
// Presents the Downloads screen (queue + library) full screen.
extern void YMPresentDownloadsViewController(UIViewController *presenter);
// Root view controller of the Downloads tab (one shared instance).
extern UIViewController *YMDownloadsTabViewController(void);
extern void YMDownloadsTabReturnToTop(UIViewController *tab);
// The pivot bar currently on screen (set by Tabbar.x), for the tab's bottom inset.
extern UIView *YMDownloadsTabPivotBarView(void);
