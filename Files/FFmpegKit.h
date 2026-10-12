#import <Foundation/Foundation.h>

// See FFmpegKit.x. All callbacks run on the main queue.
typedef void (^YMFFmpegProgress)(float fraction);
typedef void (^YMFFmpegCompletion)(BOOL success, BOOL cancelled, NSString *errorMessage);

// The frameworks are present on disk (cheap; does not load them).
extern BOOL YMFFmpegInstalled(void);
// Loads FFmpegKit on first call; YES once it is usable.
extern BOOL YMFFmpegAvailable(void);
// Runs ffmpeg with `arguments`. `durationMs` (0 if unknown) drives progress.
extern void YMFFmpegRun(NSArray<NSString *> *arguments, unsigned long long durationMs, YMFFmpegProgress progress, YMFFmpegCompletion completion);
extern void YMFFmpegCancel(void);
extern NSString *YMFFmpegDiagnostics(void);
