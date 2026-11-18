// Some are adapted from https://github.com/Mark02-2012/YTPlaybackFix
#import "Headers.h"
#import <objc/message.h>

/* Old method
static BOOL isReloaded = NO;

%hook YTPlayerViewController
- (int)state {
    int value = %orig;
    if (![self.UIDelegate isKindOfClass:%c(YTWatchController)]) return value;
    if (value == 7) {
        if (!isReloaded) {
            isReloaded = YES;
            YTWatchController *watchController = (YTWatchController *)self.UIDelegate;
            dispatch_async(dispatch_get_main_queue(), ^{  
                [watchController reload];
            });
        }
    } else {
        isReloaded = NO;
    }
    return value;
}
%end
*/

// Recent playback errors, kept for the UI dump (a "playback fails after N seconds" report needs the real error).
static NSMutableArray<NSString *> *gYMPlaybackErrors;
NSString *YMPlaybackErrorLog(void) {
    @synchronized ([NSNull null]) {
        return gYMPlaybackErrors.count ? [gYMPlaybackErrors componentsJoinedByString:@"\n"] : @"(none since launch)";
    }
}
static void YMRecordPlaybackError(NSError *error, id controller) {
    if (!error) return;
    NSString *info = [[error.userInfo description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (info.length > 1800) info = [[info substringToIndex:1800] stringByAppendingString:@"…"];
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying) info = [info stringByAppendingFormat:@" | underlying: %@ %ld %@", underlying.domain, (long)underlying.code, underlying.localizedDescription];
    NSString *time = @"?";
    @try {
        id player = [controller valueForKey:@"parentViewController"];
        if ([player respondsToSelector:@selector(currentVideoMediaTime)]) time = [NSString stringWithFormat:@"%.1f", ((CGFloat (*)(id, SEL))objc_msgSend)(player, @selector(currentVideoMediaTime))];
    } @catch (__unused NSException *e) {}
    NSString *entry = [NSString stringWithFormat:@"%@ at media time %@s: %@ code %ld - %@ | %@", [NSDate date], time, error.domain, (long)error.code, error.localizedDescription, info];
    @synchronized ([NSNull null]) {
        if (!gYMPlaybackErrors) gYMPlaybackErrors = [NSMutableArray array];
        [gYMPlaybackErrors addObject:entry];
        if (gYMPlaybackErrors.count > 20) [gYMPlaybackErrors removeObjectAtIndex:0];
    }
}

%hook YTMainAppVideoPlayerOverlayViewController
- (void)handleError:(NSError *)error {
    YMRecordPlaybackError(error, self);
    // At most 3 automatic reloads a minute, so a video the server keeps refusing ends on the error screen
    static NSMutableArray<NSDate *> *reloads;
    BOOL reloadOK = NO;
    if (IS_ENABLED(FixPlaybackIssues) && error && [error.domain isEqualToString:@"com.google.ios.youtube.ErrorDomain.playback"] && error.code == 14) {
        if (!reloads) reloads = [NSMutableArray array];
        NSDate *now = [NSDate date];
        for (NSInteger i = (NSInteger)reloads.count - 1; i >= 0; i--) if ([now timeIntervalSinceDate:reloads[i]] > 60) [reloads removeObjectAtIndex:i];
        if (reloads.count < 3) { [reloads addObject:now]; reloadOK = YES; }
    }
    if (reloadOK) {
        YTPlayerViewController *playerViewController = self.parentViewController;
        if (![playerViewController.UIDelegate isKindOfClass:%c(YTWatchController)]) return;
        YTWatchController *watchController = (YTWatchController *)playerViewController.UIDelegate;
        dispatch_async(dispatch_get_main_queue(), ^{  
            [watchController reload];
        });
        return;
    }
    %orig;
}
%end

%ctor {
    YMRegisterDefaults();
    %init;
}