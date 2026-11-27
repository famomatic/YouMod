#import "Headers.h"

// Optional: send YouTube's /player and /initplayback requests as the TVHTML5_SIMPLY client (PS4 browser) instead of
// the iOS app. Since 2026-11-18 the iOS client's /player answers some videos with error 14 ("Something went wrong.
// Refresh and try again later."); uYouEnhanced works around it the same way (Sources/FixPlayback.xm). Default OFF:
// the answer is for another client, so things tied to the iOS client (watch history, downloads, signed-in
// recommendations) may behave differently. Only the playback endpoints are changed - /browse and /next must keep
// the app's own context. Read at launch.
static NSString *gYMSpoofLog = @"off";
NSString *YMPlayerSpoofLog(void) { @synchronized ([NSNull null]) { return gYMSpoofLog; } }

static NSInteger gYMSpoofedBodies = 0, gYMSpoofedMedia = 0;
static NSMutableOrderedSet<NSString *> *gYMSpoofSeen; // "via path" of youtubei requests that passed a hook, for the dump
static void YMSpoofSeen(NSString *via, NSURL *url) {
    if (![url.path.lowercaseString containsString:@"youtubei"]) return;
    @synchronized ([NSNull null]) {
        if (!gYMSpoofSeen) gYMSpoofSeen = [NSMutableOrderedSet orderedSet];
        if (gYMSpoofSeen.count < 12) [gYMSpoofSeen addObject:[NSString stringWithFormat:@"%@ %@", via, url.path]];
    }
}
static void YMSpoofNote(void) {
    @synchronized ([NSNull null]) {
        gYMSpoofLog = [NSString stringWithFormat:@"on (TVHTML5_SIMPLY): %ld /player bodies, %ld videoplayback requests rewritten; youtubei requests seen: %@", (long)gYMSpoofedBodies, (long)gYMSpoofedMedia, gYMSpoofSeen.count ? [gYMSpoofSeen.array componentsJoinedByString:@", "] : @"none"];
    }
}

static NSString *const kYMSpoofClientName = @"75";
static NSString *const kYMSpoofClientVersion = @"1.1";
static NSString *const kYMSpoofUserAgent = @"Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)";
static NSString *gYMSpoofVisitorData = nil;

static BOOL YMSpoofIsPlayerPath(NSString *path) {
    NSString *p = path.lowercaseString;
    return p.length && ([p containsString:@"/player"] || [p containsString:@"/initplayback"]);
}
static BOOL YMSpoofIsMediaPath(NSString *path) { return [path.lowercaseString containsString:@"/videoplayback"]; }

static void YMSpoofApplyHeaders(NSMutableURLRequest *request, BOOL includeContentType) {
    NSString *visitor;
    @synchronized ([NSNull null]) { visitor = gYMSpoofVisitorData; }
    if (includeContentType) [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"*" forHTTPHeaderField:@"Accept-Language"];
    [request setValue:kYMSpoofClientName forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:kYMSpoofClientVersion forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [request setValue:kYMSpoofUserAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    if (visitor.length) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
}

static void YMSpoofApplyBody(NSMutableURLRequest *request) {
    if (!request.HTTPBody || !YMSpoofIsPlayerPath(request.URL.path)) return;
    NSDictionary *incoming = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    if (![incoming isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *incomingContext = incoming[@"context"];
    NSDictionary *incomingClient = [incomingContext isKindOfClass:[NSDictionary class]] ? incomingContext[@"client"] : nil;
    if ([incomingClient isKindOfClass:[NSDictionary class]] && [incomingClient[@"visitorData"] isKindOfClass:[NSString class]]) {
        @synchronized ([NSNull null]) { gYMSpoofVisitorData = [incomingClient[@"visitorData"] copy]; }
    }
    NSString *visitor;
    @synchronized ([NSNull null]) { visitor = gYMSpoofVisitorData; }
    NSMutableDictionary *client = [@{
        @"clientName": @"TVHTML5_SIMPLY", @"clientVersion": kYMSpoofClientVersion, @"hl": @"en", @"timeZone": @"UTC", @"utcOffsetMinutes": @0,
        @"deviceMake": @"Sony", @"deviceModel": @"PS4", @"osName": @"", @"osVersion": @"7.20260707.07.00", @"clientPlatform": @"GAME_CONSOLE",
        @"userAgent": kYMSpoofUserAgent } mutableCopy];
    if (visitor.length) client[@"visitorData"] = visitor;
    NSMutableDictionary *body = [incoming mutableCopy];
    NSMutableDictionary *context = [incomingContext isKindOfClass:[NSDictionary class]] ? [incomingContext mutableCopy] : [NSMutableDictionary dictionary];
    context[@"client"] = client;
    body[@"context"] = context;
    NSData *rebuilt = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (rebuilt) { request.HTTPBody = rebuilt; gYMSpoofedBodies++; YMSpoofNote(); }
}

static void YMSpoofHandle(NSMutableURLRequest *request) {
    if (!request.URL) return;
    YMSpoofSeen(@"request", request.URL);
    NSString *path = request.URL.path;
    if (YMSpoofIsPlayerPath(path)) { YMSpoofApplyBody(request); YMSpoofApplyHeaders(request, YES); }
    else if (YMSpoofIsMediaPath(path)) { YMSpoofApplyHeaders(request, NO); gYMSpoofedMedia++; YMSpoofNote(); }
}

// A copy of the request with the playback rewrite applied (for tasks created straight on an NSURLSession)
static NSURLRequest *YMSpoofedCopy(NSURLRequest *request, NSData *uploadBody, NSData **newBody) {
    if (![request isKindOfClass:[NSURLRequest class]] || !request.URL) return request;
    NSString *path = request.URL.path;
    if (!YMSpoofIsPlayerPath(path) && !YMSpoofIsMediaPath(path)) { YMSpoofSeen(@"session", request.URL); return request; }
    NSMutableURLRequest *copy = [request mutableCopy];
    if (uploadBody && !copy.HTTPBody) {
        copy.HTTPBody = uploadBody; // YMSpoofApplyBody works on HTTPBody
        YMSpoofHandle(copy);
        if (newBody) *newBody = copy.HTTPBody;
        copy.HTTPBody = nil;
    } else {
        YMSpoofHandle(copy);
    }
    return copy;
}

@interface GTMSessionFetcher : NSObject
- (id)mutableRequestForTesting;
@end

%group SpoofPlayerClient
%hook NSURLSession
- (id)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(YMSpoofedCopy(request, nil, NULL));
}
- (id)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(id)handler {
    return %orig(YMSpoofedCopy(request, nil, NULL), handler);
}
- (id)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data {
    NSData *body = nil;
    NSURLRequest *r = YMSpoofedCopy(request, data, &body);
    return %orig(r, body ?: data);
}
- (id)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)data completionHandler:(id)handler {
    NSData *body = nil;
    NSURLRequest *r = YMSpoofedCopy(request, data, &body);
    return %orig(r, body ?: data, handler);
}
%end

%hook NSMutableURLRequest
- (id)initWithURL:(NSURL *)URL cachePolicy:(unsigned long long)cachePolicy timeoutInterval:(double)timeoutInterval {
    self = %orig;
    if (self && URL) YMSpoofHandle(self);
    return self;
}
%end

%hook GTMSessionFetcher
- (id)initWithRequest:(id)request {
    if ([request isKindOfClass:[NSURLRequest class]] && [request URL]) {
        NSMutableURLRequest *patched = [request mutableCopy];
        YMSpoofHandle(patched);
        request = patched;
    }
    return %orig(request);
}
- (id)initWithRequest:(id)request configuration:(id)configuration {
    if ([request isKindOfClass:[NSURLRequest class]] && [request URL]) {
        NSMutableURLRequest *patched = [request mutableCopy];
        YMSpoofHandle(patched);
        request = patched;
    }
    return %orig(request, configuration);
}
- (void)updateMutableRequest:(id)request {
    if ([request isKindOfClass:[NSMutableURLRequest class]]) YMSpoofHandle(request);
    %orig(request);
}
- (void)setBodyData:(id)data {
    %orig(data);
    NSMutableURLRequest *request = [self mutableRequestForTesting];
    if ([request isKindOfClass:[NSMutableURLRequest class]]) YMSpoofApplyBody(request);
}
%end
%end

%ctor {
    YMRegisterDefaults();
    if (IS_ENABLED(SpoofPlayerClient)) { %init(SpoofPlayerClient); YMSpoofNote(); }
}
