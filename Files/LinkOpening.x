#import "Headers.h"

// Open links in Safari / the default browser instead of Chrome or the Google app. YouTube checks whether
// googlechrome:// (or the Google app's scheme) can be opened and, if so, hands links to that app. With the setting
// on those schemes are reported as not installed, and a link that is still opened through one of them is rewritten
// to its https/http address. Read at launch; what happened is listed in the UI dump.
static NSString *gYMLinkLog = @"(no external browser link seen)";
NSString *YMLinkOpenLog(void) { return gYMLinkLog; }

static BOOL YMIsBrowserAppScheme(NSString *scheme) {
    NSString *s = scheme.lowercaseString;
    return [s isEqualToString:@"googlechrome"] || [s isEqualToString:@"googlechromes"] || [s isEqualToString:@"googlechrome-x-callback"] ||
           [s isEqualToString:@"googleapp"] || [s isEqualToString:@"google"] || [s isEqualToString:@"opera-http"] || [s isEqualToString:@"opera-https"];
}

static NSURL *YMWebURLForBrowserAppURL(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString;
    if (!YMIsBrowserAppScheme(scheme)) return nil;
    NSString *string = url.absoluteString;
    NSString *rest = [string substringFromIndex:MIN(string.length, scheme.length + 3)]; // after "scheme://"
    if ([scheme isEqualToString:@"googlechrome"] || [scheme isEqualToString:@"opera-http"]) return [NSURL URLWithString:[@"http://" stringByAppendingString:rest]];
    if ([scheme isEqualToString:@"googlechromes"] || [scheme isEqualToString:@"opera-https"]) return [NSURL URLWithString:[@"https://" stringByAppendingString:rest]];
    // googlechrome-x-callback://x-callback-url/open/?url=<encoded>&..., googleapp://open?url=<encoded>
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"] && item.value.length) {
            NSURL *target = [NSURL URLWithString:item.value];
            if (target.scheme.length && !YMIsBrowserAppScheme(target.scheme)) return target;
        }
    }
    return nil;
}

static void YMNoteLink(NSString *note) { gYMLinkLog = note; }

%group OpenLinksInSafari
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if ([url isKindOfClass:[NSURL class]] && YMIsBrowserAppScheme(url.scheme)) return NO;
    return %orig;
}
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(void (^)(BOOL))completion {
    NSURL *web = [url isKindOfClass:[NSURL class]] ? YMWebURLForBrowserAppURL(url) : nil;
    if (web) {
        YMNoteLink([NSString stringWithFormat:@"rewrote %@:// -> %@", url.scheme, web.scheme]);
        %orig(web, options, completion);
        return;
    }
    %orig;
}
- (BOOL)openURL:(NSURL *)url {
    NSURL *web = [url isKindOfClass:[NSURL class]] ? YMWebURLForBrowserAppURL(url) : nil;
    if (web) {
        YMNoteLink([NSString stringWithFormat:@"rewrote %@:// -> %@ (openURL:)", url.scheme, web.scheme]);
        return %orig(web);
    }
    return %orig;
}
%end
%end

%ctor {
    YMRegisterDefaults();
    if (IS_ENABLED(OpenLinksInSafari)) {
        %init(OpenLinksInSafari);
        YMNoteLink(@"on, nothing opened through a browser app yet");
    } else {
        YMNoteLink(@"off");
    }
}
