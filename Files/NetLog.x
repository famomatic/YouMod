#import "Headers.h"
#import <objc/runtime.h>

// What the app sends to YouTube, for the UI dump: one line per API / stats / tracking request (host + path, no query,
// no body) and the HTTP status the answer came back with, newest last. Media downloads (googlevideo videoplayback)
// are only counted. "Playback is not recorded in the history" and "error 14 every minute" are both about requests
// the server answers (or does not receive), and the app does not say which; this does.
static NSMutableArray<NSString *> *gYMNetLog;
static NSInteger gYMMediaRequests = 0;

static BOOL YMNetInteresting(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    return host && ([host containsString:@"youtube"] || [host containsString:@"googlevideo"] || [host containsString:@"google.com"] || [host containsString:@"gstatic"]) && ![host hasPrefix:@"i.ytimg"];
}

static void YMNetNote(NSString *line) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; });
    @synchronized ([NSNull null]) {
        if (!gYMNetLog) gYMNetLog = [NSMutableArray array];
        [gYMNetLog addObject:[NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], line]];
        if (gYMNetLog.count > 120) [gYMNetLog removeObjectsInRange:NSMakeRange(0, gYMNetLog.count - 120)];
    }
}

static void YMNetRequest(NSURL *url, NSString *via) {
    if (!YMNetInteresting(url)) return;
    if ([url.path.lowercaseString containsString:@"videoplayback"]) { @synchronized ([NSNull null]) { gYMMediaRequests++; } return; }
    YMNetNote([NSString stringWithFormat:@"-> %@%@ (%@)", url.host, url.path, via]);
}

static void YMNetResponse(NSURL *url, NSInteger status, NSError *error) {
    if (!YMNetInteresting(url) || [url.path.lowercaseString containsString:@"videoplayback"]) return;
    YMNetNote([NSString stringWithFormat:@"<- %ld%@ %@%@", (long)status, error ? [NSString stringWithFormat:@" error %ld", (long)error.code] : @"", url.host, url.path]);
}

NSString *YMNetLog(void) {
    @synchronized ([NSNull null]) {
        NSString *body = gYMNetLog.count ? [gYMNetLog componentsJoinedByString:@"\n"] : @"(no YouTube API request seen through the hooked paths)";
        return [NSString stringWithFormat:@"media (videoplayback) requests: %ld\n%@", (long)gYMMediaRequests, body];
    }
}

%hook NSMutableURLRequest
- (id)initWithURL:(NSURL *)URL cachePolicy:(unsigned long long)cachePolicy timeoutInterval:(double)timeoutInterval {
    self = %orig;
    if (self && URL) YMNetRequest(URL, @"request");
    return self;
}
%end

@interface GTMSessionFetcher : NSObject
@end

%hook GTMSessionFetcher
- (void)beginFetchWithCompletionHandler:(void (^)(NSData *, NSError *))handler {
    NSURLRequest *request = nil;
    @try { request = [self valueForKey:@"request"]; } @catch (__unused NSException *e) {}
    NSURL *url = [request isKindOfClass:[NSURLRequest class]] ? request.URL : nil;
    if (url) YMNetRequest(url, @"fetcher");
    if (!url || !YMNetInteresting(url) || !handler) { %orig; return; }
    __weak id weakSelf = self;
    %orig(^(NSData *data, NSError *error) {
        NSInteger status = 0;
        @try { id s = [weakSelf valueForKey:@"statusCode"]; status = [s integerValue]; } @catch (__unused NSException *e) {}
        YMNetResponse(url, status, error);
        handler(data, error);
    });
}
%end

%hook NSURLSession
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURL *url = [request isKindOfClass:[NSURLRequest class]] ? request.URL : nil;
    if (url) YMNetRequest(url, @"session");
    if (!url || !YMNetInteresting(url) || !handler) return %orig;
    return %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
        YMNetResponse(url, [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0, error);
        handler(data, response, error);
    });
}
%end

%ctor {
    YMRegisterDefaults();
    %init;
}
