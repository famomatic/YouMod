// ytv1 download method: YTV1.framework (famomatic/ytv1, a Go YouTube extractor -
// see ytv1bridge/ and tools/build-ytv1.sh) resolves and downloads the chosen
// formats itself, independently of the YouTube app's own player state. It is
// dlopen'd on first use, from the same places as FFmpegKit:
//   YouTube.app/Frameworks              (sideloaded IPA - injected by ipa.yml)
//   YouTube.app/YouMod.bundle/Frameworks
//   <jbroot>/Library/Application Support/YouMod.bundle/Frameworks (jailbreak deb)
#import "Headers.h"
#import <dlfcn.h>

typedef void (*YMYTV1ProgressFn)(void *ctx, int64_t downloaded, int64_t total);
typedef void (*YMYTV1DoneFn)(void *ctx, const char *path, int itag, const char *mime, const char *error);
typedef int64_t (*YMYTV1DownloadFn)(const char *videoID, int itag, int audio, int height, int fps, const char *mime,
                                    const char *dir, const char *base, YMYTV1ProgressFn progress, YMYTV1DoneFn done, void *ctx);
typedef void (*YMYTV1CancelFn)(int64_t handle);
typedef char *(*YMYTV1VersionFn)(void);
typedef void (*YMYTV1FreeFn)(char *p);

static YMYTV1DownloadFn ymYTV1Download;
static YMYTV1CancelFn ymYTV1Cancel;
static YMYTV1VersionFn ymYTV1Version;
static YMYTV1FreeFn ymYTV1Free;
static NSString *ymYTV1LoadError;

static NSString *YMYTV1BinaryPath(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    if (NSBundle.mainBundle.privateFrameworksPath) [dirs addObject:NSBundle.mainBundle.privateFrameworksPath];
    if (NSBundle.mainBundle.resourcePath) [dirs addObject:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"YouMod.bundle/Frameworks"]];
    [dirs addObject:jbroot(@"/Library/Application Support/YouMod.bundle/Frameworks")];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:@"YTV1.framework/YTV1"];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return nil;
}

static BOOL YMYTV1Load(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = YMYTV1BinaryPath();
        if (!path) { ymYTV1LoadError = @"YTV1.framework not found"; return; }
        dlerror();
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *err = dlerror();
            ymYTV1LoadError = [NSString stringWithFormat:@"dlopen YTV1 failed: %s", err ?: "?"];
            return;
        }
        ymYTV1Download = (YMYTV1DownloadFn)dlsym(handle, "ytv1_download");
        ymYTV1Cancel = (YMYTV1CancelFn)dlsym(handle, "ytv1_cancel");
        ymYTV1Version = (YMYTV1VersionFn)dlsym(handle, "ytv1_version");
        ymYTV1Free = (YMYTV1FreeFn)dlsym(handle, "ytv1_free");
        loaded = ymYTV1Download && ymYTV1Cancel;
        if (!loaded) ymYTV1LoadError = @"YTV1.framework is missing its exports";
    });
    return loaded;
}

// Callbacks arrive on Go threads, possibly after a job was cancelled; they carry a
// token, not an object, so a late call only finds nothing in the table.
typedef void (^YMYTV1ProgressBlock)(int64_t downloaded, int64_t total);
typedef void (^YMYTV1DoneBlock)(NSString *path, int itag, NSString *mime, NSString *error);

@interface YMYTV1Job : NSObject
@property (nonatomic, copy) YMYTV1ProgressBlock progress;
@property (nonatomic, copy) YMYTV1DoneBlock done;
@property (nonatomic, assign) int64_t handle;
@end
@implementation YMYTV1Job @end

static NSMutableDictionary<NSNumber *, YMYTV1Job *> *YMYTV1Jobs(void) {
    static NSMutableDictionary *jobs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ jobs = [NSMutableDictionary dictionary]; });
    return jobs;
}

static YMYTV1Job *YMYTV1JobForToken(void *ctx, BOOL remove) {
    NSNumber *key = @((uintptr_t)ctx);
    NSMutableDictionary *jobs = YMYTV1Jobs();
    @synchronized(jobs) {
        YMYTV1Job *job = jobs[key];
        if (remove) [jobs removeObjectForKey:key];
        return job;
    }
}

static void YMYTV1ProgressTrampoline(void *ctx, int64_t downloaded, int64_t total) {
    YMYTV1Job *job = YMYTV1JobForToken(ctx, NO);
    if (job.progress) job.progress(downloaded, total);
}

static void YMYTV1DoneTrampoline(void *ctx, const char *path, int itag, const char *mime, const char *error) {
    YMYTV1Job *job = YMYTV1JobForToken(ctx, YES);
    if (!job.done) return;
    NSString *p = path ? @(path) : nil;
    NSString *e = error ? @(error) : nil;
    job.done(p, itag, mime ? @(mime) : nil, e ?: (p ? nil : @"ytv1 download failed"));
}

static int64_t YMYTV1Start(NSString *videoID, YouModMediaFormat *format, BOOL audio, NSString *dir, NSString *base,
                           YMYTV1ProgressBlock progress, YMYTV1DoneBlock done) {
    static uintptr_t nextToken;
    YMYTV1Job *job = [YMYTV1Job new];
    job.progress = progress;
    job.done = done;
    uintptr_t token;
    NSMutableDictionary *jobs = YMYTV1Jobs();
    @synchronized(jobs) {
        token = ++nextToken;
        jobs[@(token)] = job;
    }
    int64_t handle = ymYTV1Download(videoID.UTF8String, format.itag, audio ? 1 : 0, format.resolution, format.fps,
                                    (format.mimeType ?: @"").UTF8String, dir.fileSystemRepresentation, base.UTF8String,
                                    YMYTV1ProgressTrampoline, YMYTV1DoneTrampoline, (void *)token);
    job.handle = handle;
    return handle;
}

static void YMYTV1ApplyActualFormat(YouModMediaFormat *format, int itag, NSString *mime) {
    if (itag <= 0 || itag == format.itag) return;
    format.itag = itag;
    if (mime.length) format.mimeType = mime;
}

@implementation YMYTV1

static NSMutableArray<NSNumber *> *ymYTV1Active;

+ (BOOL)available {
    return YMYTV1BinaryPath() != nil;
}

+ (NSString *)loadError {
    YMYTV1Load();
    return ymYTV1LoadError;
}

+ (NSString *)version {
    if (!YMYTV1Load() || !ymYTV1Version) return nil;
    char *v = ymYTV1Version();
    NSString *s = v ? @(v) : nil;
    if (v && ymYTV1Free) ymYTV1Free(v);
    return s;
}

static NSString *YMYTV1WorkDirectory(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"YouModYTV1" stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static void YMYTV1Track(int64_t handle, BOOL add) {
    @synchronized([YMYTV1 class]) {
        if (!ymYTV1Active) ymYTV1Active = [NSMutableArray array];
        if (add) [ymYTV1Active addObject:@(handle)];
        else [ymYTV1Active removeObject:@(handle)];
    }
}

+ (void)downloadVideoFormat:(YouModMediaFormat *)videoFormat audioFormat:(YouModMediaFormat *)audioFormat videoID:(NSString *)videoID
                   progress:(void (^)(float fraction, unsigned long long bytesDownloaded, BOOL isAudio))progress
                 completion:(void (^)(NSURL *videoURL, NSURL *audioURL, NSString *err))completion {
    if (!YMYTV1Load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, ymYTV1LoadError ?: @"ytv1 unavailable"); });
        return;
    }
    NSString *dir = YMYTV1WorkDirectory();
    // Both streams download in parallel; progress is reported over their sum.
    __block int64_t vDone = 0, vTotal = (int64_t)videoFormat.contentLength, aDone = 0, aTotal = (int64_t)audioFormat.contentLength;
    __block NSString *videoPath = nil, *audioPath = nil, *firstError = nil, *videoMime = nil, *audioMime = nil;
    __block int videoItag = 0, audioItag = 0;
    __block int remaining = 2;
    __block int64_t vHandle = 0, aHandle = 0;
    NSObject *lock = [NSObject new];

    void (^report)(void) = ^{
        int64_t done, total;
        @synchronized(lock) { done = vDone + aDone; total = vTotal + aTotal; }
        float fraction = total > 0 ? (float)((double)done / (double)total) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ if (progress) progress(fminf(fraction, 1.0f), (unsigned long long)done, NO); });
    };
    void (^finishOne)(void) = ^{
        BOOL last;
        @synchronized(lock) { last = (--remaining == 0); }
        if (!last) return;
        YMYTV1Track(vHandle, NO);
        YMYTV1Track(aHandle, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (firstError || !videoPath || !audioPath) {
                completion(nil, nil, firstError ?: @"ytv1 download failed");
            } else {
                // ytv1 may have substituted the closest format; the merge decides by these
                YMYTV1ApplyActualFormat(videoFormat, videoItag, videoMime);
                YMYTV1ApplyActualFormat(audioFormat, audioItag, audioMime);
                completion([NSURL fileURLWithPath:videoPath], [NSURL fileURLWithPath:audioPath], nil);
            }
        });
    };

    vHandle = YMYTV1Start(videoID, videoFormat, NO, dir, @"video", ^(int64_t d, int64_t t) {
        @synchronized(lock) { vDone = d; if (t > 0) vTotal = t; }
        report();
    }, ^(NSString *path, int itag, NSString *mime, NSString *error) {
        @synchronized(lock) {
            videoPath = path; videoItag = itag; videoMime = mime;
            if (error && !firstError) firstError = error;
        }
        // one stream failed: stop the other instead of waiting for it
        if (error && ymYTV1Cancel) ymYTV1Cancel(aHandle);
        finishOne();
    });
    YMYTV1Track(vHandle, YES);
    aHandle = YMYTV1Start(videoID, audioFormat, YES, dir, @"audio", ^(int64_t d, int64_t t) {
        @synchronized(lock) { aDone = d; if (t > 0) aTotal = t; }
        report();
    }, ^(NSString *path, int itag, NSString *mime, NSString *error) {
        @synchronized(lock) {
            audioPath = path; audioItag = itag; audioMime = mime;
            if (error && !firstError) firstError = error;
        }
        if (error && ymYTV1Cancel) ymYTV1Cancel(vHandle);
        finishOne();
    });
    YMYTV1Track(aHandle, YES);
}

+ (void)downloadAudioFormat:(YouModMediaFormat *)audioFormat videoID:(NSString *)videoID
                   progress:(void (^)(float fraction, unsigned long long bytesDownloaded))progress
                 completion:(void (^)(NSURL *audioURL, NSString *err))completion {
    if (!YMYTV1Load()) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, ymYTV1LoadError ?: @"ytv1 unavailable"); });
        return;
    }
    NSString *dir = YMYTV1WorkDirectory();
    __block int64_t handle = 0;
    int64_t expected = (int64_t)audioFormat.contentLength;
    handle = YMYTV1Start(videoID, audioFormat, YES, dir, @"audio", ^(int64_t d, int64_t t) {
        int64_t total = t > 0 ? t : expected;
        float fraction = total > 0 ? (float)((double)d / (double)total) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{ if (progress) progress(fminf(fraction, 1.0f), (unsigned long long)d); });
    }, ^(NSString *path, int itag, NSString *mime, NSString *error) {
        YMYTV1Track(handle, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (path) YMYTV1ApplyActualFormat(audioFormat, itag, mime);
            completion(path ? [NSURL fileURLWithPath:path] : nil, error);
        });
    });
    YMYTV1Track(handle, YES);
}

+ (void)cancelCurrent {
    if (!ymYTV1Cancel) return;
    NSArray *handles;
    @synchronized([YMYTV1 class]) { handles = ymYTV1Active.copy; [ymYTV1Active removeAllObjects]; }
    for (NSNumber *h in handles) ymYTV1Cancel(h.longLongValue);
}

@end
