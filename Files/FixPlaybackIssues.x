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

// Resume after the automatic reload. A reload starts the video from 0 and, with "Disable autoplay" on, paused.
// The position is the last one playback reached or the target of the last seek (a seek is what the server tends to
// refuse, and by then YouTube reports 0), and for a short window after the reload the video is made to start
// playing and is moved back to that position.
static double gYMLastTime = 0;
static NSString *gYMLastVideoID = nil;
static double gYMResumeTime = 0;
static NSString *gYMResumeVideoID = nil;
static NSDate *gYMResumeUntil = nil;

BOOL YMPlaybackResumeActive(void) { return gYMResumeUntil && [gYMResumeUntil timeIntervalSinceNow] > 0; }

static NSString *YMCurrentVideoID(id player) {
    @try { id v = [player valueForKey:@"currentVideoID"]; return [v isKindOfClass:[NSString class]] ? v : nil; } @catch (__unused NSException *e) { return nil; }
}
static double YMCurrentMediaTime(id player) {
    return [player respondsToSelector:@selector(currentVideoMediaTime)] ? ((double (*)(id, SEL))objc_msgSend)(player, @selector(currentVideoMediaTime)) : 0;
}
static void YMNoteSeek(id player, double time) {
    if (YMPlaybackResumeActive() || !(time > 0) || time > 1e7) return;
    gYMLastTime = time;
    gYMLastVideoID = [YMCurrentVideoID(player) copy];
}

%hook YTPlayerViewController
- (void)seekToTime:(double)time { YMNoteSeek(self, time); %orig; }
- (void)seekToTime:(double)time seekSource:(int)source { YMNoteSeek(self, time); %orig; }
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after seekSource:(int)source { YMNoteSeek(self, time); %orig; }
- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    NSString *vid = YMCurrentVideoID(self);
    if (!vid) return;
    double now = YMCurrentMediaTime(self);
    if (YMPlaybackResumeActive()) {
        if (![vid isEqualToString:gYMResumeVideoID]) return;
        if (now >= gYMResumeTime - 2) { gYMResumeUntil = nil; return; } // already there
        gYMResumeUntil = nil;
        double target = gYMResumeTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, double))objc_msgSend)(self, @selector(seekToTime:), target);
            if ([self respondsToSelector:@selector(play)]) ((void (*)(id, SEL))objc_msgSend)(self, @selector(play));
        });
        return;
    }
    if (now > 1) { gYMLastTime = now; gYMLastVideoID = [vid copy]; }
}
%end

%hook YTMainAppVideoPlayerOverlayViewController
- (void)handleError:(NSError *)error {
    YMRecordPlaybackError(error, self);
    // Retry with growing pauses (1.5 s, 4 s, 8 s, 15 s, 30 s) instead of reloading again at once: the server's answer is
    // "try again later" and reloading every 2 seconds only kept it failing. After the fifth try, or when the user has
    // left the video, the error screen is left alone. The count starts over after 40 quiet seconds.
    static BOOL reloadPending = NO;
    static NSInteger retries = 0;
    static NSDate *lastRetry = nil;
    if (IS_ENABLED(FixPlaybackIssues) && error && [error.domain isEqualToString:@"com.google.ios.youtube.ErrorDomain.playback"] && error.code == 14) {
        YTPlayerViewController *playerViewController = self.parentViewController;
        if (![playerViewController.UIDelegate isKindOfClass:%c(YTWatchController)]) return;
        if (reloadPending) return; // one retry is already on its way; the player reports the same failure several times
        NSDate *now = [NSDate date];
        if (lastRetry && [now timeIntervalSinceDate:lastRetry] > 40) retries = 0;
        static const double delays[] = {1.5, 4, 8, 15, 30};
        if (retries < 5) {
            YTWatchController *watchController = (YTWatchController *)playerViewController.UIDelegate;
            NSString *vid = YMCurrentVideoID(playerViewController);
            double at = (vid && [vid isEqualToString:gYMLastVideoID] && gYMLastTime > 1) ? gYMLastTime : YMCurrentMediaTime(playerViewController);
            double resumeAt = at > 1 ? at : 0;
            double delay = delays[retries];
            retries++;
            lastRetry = now;
            reloadPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                reloadPending = NO;
                if (vid && ![YMCurrentVideoID(playerViewController) isEqualToString:vid]) return; // the user moved on
                gYMResumeVideoID = [vid copy];
                gYMResumeTime = resumeAt;
                gYMResumeUntil = [NSDate dateWithTimeIntervalSinceNow:resumeAt > 0 ? 25 : 8];
                // start playing right away (reload alone follows "Disable autoplay" and stays paused)
                if ([watchController respondsToSelector:@selector(reloadStartPlayback:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(watchController, @selector(reloadStartPlayback:), YES);
                else [watchController reload];
            });
            return;
        }
    }
    %orig;
}
%end

%ctor {
    YMRegisterDefaults();
    %init;
}