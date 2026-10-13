#import "Headers.h"
#import "DownloadLibrary.h"

NSString *const YMDownloadLibraryDidChangeNotification = @"YMDownloadLibraryDidChangeNotification";

static NSString *const YMLibraryIndexName = @".library.json";
static NSString *const YMLibraryThumbnailFolder = @".thumbnails";

@implementation YMDownloadItem

- (NSURL *)fileURL {
    return self.fileName.length ? [[YMDownloadLibrary downloadsDirectoryURL] URLByAppendingPathComponent:self.fileName] : nil;
}

- (NSURL *)thumbnailURL {
    return self.thumbnailFileName.length ? [[YMDownloadLibrary downloadsDirectoryURL] URLByAppendingPathComponent:self.thumbnailFileName] : nil;
}

- (NSDictionary *)dictionaryValue {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = self.identifier ?: @"";
    if (self.videoID) dict[@"videoID"] = self.videoID;
    if (self.title) dict[@"title"] = self.title;
    if (self.author) dict[@"author"] = self.author;
    if (self.fileName) dict[@"file"] = self.fileName;
    if (self.thumbnailFileName) dict[@"thumbnail"] = self.thumbnailFileName;
    if (self.formatSummary) dict[@"format"] = self.formatSummary;
    dict[@"video"] = @(self.isVideo);
    dict[@"size"] = @(self.fileSize);
    dict[@"durationMs"] = @(self.durationMs);
    dict[@"created"] = @(self.createdAt);
    return dict;
}

+ (instancetype)itemWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    YMDownloadItem *item = [YMDownloadItem new];
    item.identifier = dict[@"id"];
    item.videoID = dict[@"videoID"];
    item.title = dict[@"title"];
    item.author = dict[@"author"];
    item.fileName = dict[@"file"];
    item.thumbnailFileName = dict[@"thumbnail"];
    item.formatSummary = dict[@"format"];
    item.isVideo = [dict[@"video"] boolValue];
    item.fileSize = [dict[@"size"] unsignedLongLongValue];
    item.durationMs = [dict[@"durationMs"] unsignedLongLongValue];
    item.createdAt = [dict[@"created"] doubleValue];
    return item.fileName.length ? item : nil;
}

@end

@interface YMDownloadLibrary ()
@property (nonatomic, strong) NSMutableArray<YMDownloadItem *> *mutableItems;
@end

@implementation YMDownloadLibrary

+ (instancetype)sharedLibrary {
    static YMDownloadLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        library = [YMDownloadLibrary new];
        [library reload];
    });
    return library;
}

+ (NSURL *)downloadsDirectoryURL {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *downloads = [documents URLByAppendingPathComponent:@"YouMod_Downloads" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:downloads withIntermediateDirectories:YES attributes:nil error:nil];
    return downloads;
}

- (NSURL *)indexURL {
    return [[YMDownloadLibrary downloadsDirectoryURL] URLByAppendingPathComponent:YMLibraryIndexName];
}

- (NSArray<YMDownloadItem *> *)items {
    return self.mutableItems.copy ?: @[];
}

- (void)reload {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [YMDownloadLibrary downloadsDirectoryURL];
    NSMutableArray<YMDownloadItem *> *items = [NSMutableArray array];
    NSMutableSet<NSString *> *known = [NSMutableSet set];

    NSData *data = [NSData dataWithContentsOfURL:[self indexURL]];
    NSArray *stored = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([stored isKindOfClass:NSArray.class]) {
        for (NSDictionary *dict in stored) {
            YMDownloadItem *item = [YMDownloadItem itemWithDictionary:dict];
            if (!item || ![fm fileExistsAtPath:item.fileURL.path] || [known containsObject:item.fileName]) continue;
            [known addObject:item.fileName];
            [items addObject:item];
        }
    }

    // Files downloaded before the library existed (or added through Files).
    NSArray<NSURL *> *contents = [fm contentsOfDirectoryAtURL:directory includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLCreationDateKey, NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSSet *videoExtensions = [NSSet setWithArray:@[@"mp4", @"mkv", @"webm", @"mov", @"m4v"]];
    NSSet *audioExtensions = [NSSet setWithArray:@[@"m4a", @"mp3", @"opus", @"flac", @"wav", @"ogg"]];
    for (NSURL *url in contents) {
        NSString *name = url.lastPathComponent;
        NSString *extension = url.pathExtension.lowercaseString;
        if ([known containsObject:name] || [name hasPrefix:@"Temp_"]) continue;
        BOOL video = [videoExtensions containsObject:extension];
        if (!video && ![audioExtensions containsObject:extension]) continue;
        NSDictionary *values = [url resourceValuesForKeys:@[NSURLFileSizeKey, NSURLCreationDateKey] error:nil];
        YMDownloadItem *item = [YMDownloadItem new];
        item.identifier = NSUUID.UUID.UUIDString;
        item.fileName = name;
        item.title = name.stringByDeletingPathExtension;
        item.isVideo = video;
        item.fileSize = [values[NSURLFileSizeKey] unsignedLongLongValue];
        item.createdAt = [values[NSURLCreationDateKey] timeIntervalSince1970];
        [items addObject:item];
    }

    [items sortUsingComparator:^NSComparisonResult(YMDownloadItem *a, YMDownloadItem *b) {
        if (a.createdAt == b.createdAt) return NSOrderedSame;
        return a.createdAt > b.createdAt ? NSOrderedAscending : NSOrderedDescending;
    }];
    self.mutableItems = items;
    [self save];
}

- (void)save {
    NSMutableArray *array = [NSMutableArray array];
    for (YMDownloadItem *item in self.mutableItems) [array addObject:[item dictionaryValue]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:nil];
    [data writeToURL:[self indexURL] atomically:YES];
}

- (void)notifyChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:YMDownloadLibraryDidChangeNotification object:self];
    });
}

- (YMDownloadItem *)addFileURL:(NSURL *)fileURL videoID:(NSString *)videoID title:(NSString *)title author:(NSString *)author formatSummary:(NSString *)formatSummary isVideo:(BOOL)isVideo durationMs:(unsigned long long)durationMs thumbnailURL:(NSURL *)thumbnailURL {
    if (!fileURL) return nil;
    NSString *directory = [YMDownloadLibrary downloadsDirectoryURL].URLByStandardizingPath.path;
    NSString *path = fileURL.URLByStandardizingPath.path;
    // Only files inside the downloads folder are tracked (by relative name).
    if (![path hasPrefix:[directory stringByAppendingString:@"/"]]) return nil;

    YMDownloadItem *item = [YMDownloadItem new];
    item.identifier = NSUUID.UUID.UUIDString;
    item.videoID = videoID;
    item.title = title.length ? title : fileURL.URLByDeletingPathExtension.lastPathComponent;
    item.author = author;
    item.fileName = [path substringFromIndex:directory.length + 1];
    item.formatSummary = formatSummary;
    item.isVideo = isVideo;
    item.durationMs = durationMs;
    item.fileSize = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
    item.createdAt = NSDate.date.timeIntervalSince1970;

    [self.mutableItems filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(YMDownloadItem *existing, NSDictionary *bindings) {
        return ![existing.fileName isEqualToString:item.fileName];
    }]];
    [self.mutableItems insertObject:item atIndex:0];
    [self save];
    [self notifyChange];

    if (thumbnailURL) {
        [[NSURLSession.sharedSession dataTaskWithURL:thumbnailURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data.length == 0 || ![UIImage imageWithData:data]) return;
            NSURL *folder = [[YMDownloadLibrary downloadsDirectoryURL] URLByAppendingPathComponent:YMLibraryThumbnailFolder isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *thumbName = [YMLibraryThumbnailFolder stringByAppendingPathComponent:[item.identifier stringByAppendingPathExtension:@"jpg"]];
            if (![data writeToURL:[[YMDownloadLibrary downloadsDirectoryURL] URLByAppendingPathComponent:thumbName] atomically:YES]) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                item.thumbnailFileName = thumbName;
                [self save];
                [self notifyChange];
            });
        }] resume];
    }
    return item;
}

- (BOOL)replaceFileOfItem:(YMDownloadItem *)item withURL:(NSURL *)newURL formatSummary:(NSString *)formatSummary {
    if (!item || !newURL) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *directory = [YMDownloadLibrary downloadsDirectoryURL];
    NSString *base = item.fileName.stringByDeletingPathExtension.lastPathComponent ?: NSUUID.UUID.UUIDString;
    NSString *extension = newURL.pathExtension.length ? newURL.pathExtension : @"mp4";
    NSURL *target = [directory URLByAppendingPathComponent:[base stringByAppendingPathExtension:extension]];
    NSUInteger index = 2;
    while ([fm fileExistsAtPath:target.path] && ![target.path isEqualToString:item.fileURL.path]) {
        target = [directory URLByAppendingPathComponent:[[NSString stringWithFormat:@"%@ %lu", base, (unsigned long)index++] stringByAppendingPathExtension:extension]];
    }
    NSURL *oldURL = item.fileURL;
    if ([target.path isEqualToString:oldURL.path]) {
        if (![fm replaceItemAtURL:target withItemAtURL:newURL backupItemName:nil options:0 resultingItemURL:nil error:nil]) return NO;
    } else {
        if (![fm moveItemAtURL:newURL toURL:target error:nil]) return NO;
        if (oldURL) [fm removeItemAtURL:oldURL error:nil];
    }
    item.fileName = target.lastPathComponent;
    item.fileSize = [[fm attributesOfItemAtPath:target.path error:nil] fileSize];
    if (formatSummary.length) item.formatSummary = formatSummary;
    [self save];
    [self notifyChange];
    return YES;
}

static NSString *const YMResumePositionsKey = @"YouModDownloadResumePositions";

- (NSTimeInterval)resumePositionForItem:(YMDownloadItem *)item {
    if (!item.identifier) return 0;
    NSDictionary *positions = [NSUserDefaults.standardUserDefaults dictionaryForKey:YMResumePositionsKey];
    return [positions[item.identifier] doubleValue];
}

- (void)setResumePosition:(NSTimeInterval)position forItem:(YMDownloadItem *)item {
    if (!item.identifier) return;
    NSMutableDictionary *positions = [[NSUserDefaults.standardUserDefaults dictionaryForKey:YMResumePositionsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSNumber *old = positions[item.identifier];
    if (position < 1) [positions removeObjectForKey:item.identifier];
    else positions[item.identifier] = @(position);
    if ((old == nil) == (position < 1) && fabs(old.doubleValue - position) < 0.5) return;
    [NSUserDefaults.standardUserDefaults setObject:positions forKey:YMResumePositionsKey];
}

- (void)removeItem:(YMDownloadItem *)item {
    if (!item) return;
    [self setResumePosition:0 forItem:item];
    if (item.fileURL) [NSFileManager.defaultManager removeItemAtURL:item.fileURL error:nil];
    if (item.thumbnailURL) [NSFileManager.defaultManager removeItemAtURL:item.thumbnailURL error:nil];
    [self.mutableItems removeObject:item];
    [self save];
    [self notifyChange];
}

@end
