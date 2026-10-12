#import <UIKit/UIKit.h>

// Index of finished downloads in Documents/YouMod_Downloads, read by the
// Downloads tab. Persisted as JSON next to the files; files that exist without an
// entry (older downloads) are picked up, entries whose file is gone are dropped.

extern NSString *const YMDownloadLibraryDidChangeNotification;

@interface YMDownloadItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *fileName;          // relative to the downloads folder
@property (nonatomic, copy) NSString *thumbnailFileName; // relative to the downloads folder
@property (nonatomic, copy) NSString *formatSummary;     // e.g. "1080p60 · VP9 · Opus"
@property (nonatomic, assign) BOOL isVideo;
@property (nonatomic, assign) unsigned long long fileSize;
@property (nonatomic, assign) unsigned long long durationMs;
@property (nonatomic, assign) NSTimeInterval createdAt;
@property (nonatomic, readonly) NSURL *fileURL;
@property (nonatomic, readonly) NSURL *thumbnailURL;
@end

@interface YMDownloadLibrary : NSObject
+ (instancetype)sharedLibrary;
+ (NSURL *)downloadsDirectoryURL;
@property (nonatomic, readonly) NSArray<YMDownloadItem *> *items; // newest first
- (void)reload;
// Records a finished download; the thumbnail (if any) is fetched in the background.
- (YMDownloadItem *)addFileURL:(NSURL *)fileURL videoID:(NSString *)videoID title:(NSString *)title author:(NSString *)author formatSummary:(NSString *)formatSummary isVideo:(BOOL)isVideo durationMs:(unsigned long long)durationMs thumbnailURL:(NSURL *)thumbnailURL;
- (void)removeItem:(YMDownloadItem *)item; // deletes the file and its thumbnail
@end
