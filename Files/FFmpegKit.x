// FFmpegKit bridge for the downloader.
//
// FFmpegKit (ffmpeg-kit-next, full GPL build) ships as separate frameworks that are
// never linked into YouMod: linking them - or letting cyan add load commands for them
// - would load all of FFmpeg at every app launch. They are dlopen'd the first time a
// download actually needs FFmpeg, and every call goes through the ObjC runtime so this
// file builds without FFmpegKit's headers.
//
// Locations searched, in order:
//   YouTube.app/Frameworks              (sideloaded IPA - injected by ipa.yml)
//   YouTube.app/YouMod.bundle/Frameworks
//   <jbroot>/Library/Application Support/YouMod.bundle/Frameworks (jailbreak deb)
#import "Headers.h"
#import <dlfcn.h>
#import <objc/message.h>
#import "FFmpegKit.h"

static NSArray<NSString *> *YMFFmpegFrameworks(void) {
    // Dependency order: each library only links against the ones before it.
    return @[@"libavutil", @"libswresample", @"libswscale", @"libavcodec",
             @"libavformat", @"libavfilter", @"libavdevice", @"ffmpegkit"];
}

static NSMutableArray<NSString *> *YMFFmpegLog(void) {
    static NSMutableArray *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [NSMutableArray array]; });
    return log;
}

static void YMFFmpegNote(NSString *line) {
    NSMutableArray *log = YMFFmpegLog();
    @synchronized(log) {
        [log addObject:line];
        if (log.count > 100) [log removeObjectsInRange:NSMakeRange(0, log.count - 100)];
    }
}

static NSArray<NSString *> *YMFFmpegSearchDirectories(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    NSString *privateFrameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (privateFrameworks) [dirs addObject:privateFrameworks];
    NSString *resources = NSBundle.mainBundle.resourcePath;
    if (resources) [dirs addObject:[resources stringByAppendingPathComponent:@"YouMod.bundle/Frameworks"]];
    [dirs addObject:jbroot(@"/Library/Application Support/YouMod.bundle/Frameworks")];
    return dirs;
}

static NSString *YMFFmpegInstallDirectory(void) {
    for (NSString *dir in YMFFmpegSearchDirectories()) {
        NSString *binary = [dir stringByAppendingPathComponent:@"ffmpegkit.framework/ffmpegkit"];
        if ([NSFileManager.defaultManager fileExistsAtPath:binary]) return dir;
    }
    return nil;
}

BOOL YMFFmpegInstalled(void) {
    static BOOL installed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installed = YMFFmpegInstallDirectory() != nil; });
    return installed;
}

static BOOL YMFFmpegLoad(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"FFmpegKit")) { loaded = YES; return; }
        NSString *dir = YMFFmpegInstallDirectory();
        if (!dir) { YMFFmpegNote(@"FFmpegKit frameworks not found"); return; }
        for (NSString *name in YMFFmpegFrameworks()) {
            NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.framework/%@", name, name]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                YMFFmpegNote([NSString stringWithFormat:@"missing %@", path]);
                continue;
            }
            dlerror();
            if (dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
                YMFFmpegNote([NSString stringWithFormat:@"loaded %@", name]);
            } else {
                const char *err = dlerror();
                YMFFmpegNote([NSString stringWithFormat:@"failed %@: %s", name, err ?: "unknown"]);
            }
        }
        Class kit = NSClassFromString(@"FFmpegKit");
        loaded = [kit respondsToSelector:@selector(executeWithArgumentsAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:)];
        YMFFmpegNote(loaded ? @"FFmpegKit ready" : @"FFmpegKit class unavailable after load");
    });
    return loaded;
}

BOOL YMFFmpegAvailable(void) {
    return YMFFmpegInstalled() && YMFFmpegLoad();
}

static long ymFFmpegActiveSession = 0;

void YMFFmpegRun(NSArray<NSString *> *arguments, unsigned long long durationMs, YMFFmpegProgress progress, YMFFmpegCompletion completion) {
    if (!YMFFmpegAvailable()) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, NO, @"FFmpegKit is not available"); });
        return;
    }
    Class kit = NSClassFromString(@"FFmpegKit");
    SEL execute = @selector(executeWithArgumentsAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:);

    void (^complete)(id) = ^(id session) {
        Class returnCodeClass = NSClassFromString(@"ReturnCode");
        id code = ((id (*)(id, SEL))objc_msgSend)(session, @selector(getReturnCode));
        BOOL success = ((BOOL (*)(Class, SEL, id))objc_msgSend)(returnCodeClass, @selector(isSuccess:), code);
        BOOL cancelled = ((BOOL (*)(Class, SEL, id))objc_msgSend)(returnCodeClass, @selector(isCancel:), code);
        NSString *message = nil;
        if (!success && !cancelled) {
            NSString *output = ((id (*)(id, SEL))objc_msgSend)(session, @selector(getOutput));
            // The useful part of an ffmpeg failure is at the end of its output.
            message = output.length > 600 ? [output substringFromIndex:output.length - 600] : output;
            if (message.length == 0) message = @"FFmpeg failed";
            YMFFmpegNote([NSString stringWithFormat:@"ffmpeg failed: %@", message]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ymFFmpegActiveSession = 0;
            completion(success, cancelled, message);
        });
    };
    void (^log)(id) = ^(id entry) {};
    void (^statistics)(id) = ^(id stats) {
        if (!progress || durationMs == 0) return;
        double timeMs = ((double (*)(id, SEL))objc_msgSend)(stats, @selector(getTime));
        float fraction = (float)MIN(MAX(timeMs / (double)durationMs, 0.0), 1.0);
        dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction); });
    };

    id session = ((id (*)(Class, SEL, NSArray *, id, id, id))objc_msgSend)(kit, execute, arguments, complete, log, statistics);
    ymFFmpegActiveSession = ((long (*)(id, SEL))objc_msgSend)(session, @selector(getSessionId));
}

void YMFFmpegCancel(void) {
    if (!ymFFmpegActiveSession || !NSClassFromString(@"FFmpegKit")) return;
    ((void (*)(Class, SEL, long))objc_msgSend)(NSClassFromString(@"FFmpegKit"), @selector(cancel:), ymFFmpegActiveSession);
}

NSString *YMFFmpegDiagnostics(void) {
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"installed: %@", YMFFmpegInstallDirectory() ?: @"no"]];
    [lines addObject:[NSString stringWithFormat:@"loaded: %@", NSClassFromString(@"FFmpegKit") ? @"yes" : @"no"]];
    for (NSString *dir in YMFFmpegSearchDirectories()) [lines addObject:[@"searched: " stringByAppendingString:dir]];
    NSMutableArray *log = YMFFmpegLog();
    @synchronized(log) { [lines addObjectsFromArray:log]; }
    return [lines componentsJoinedByString:@"\n"];
}
