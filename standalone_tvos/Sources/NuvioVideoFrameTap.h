#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Observes CMSampleBuffers submitted to the app's existing AVFoundation
/// video renderer. No new media decoder, network connection, or seek.
typedef void (^NuvioFrameTapHandler)(UIImage *image, int64_t mediaSecond);

/// Installs one app-local renderer hook. Returns NO without modifying
/// playback when Apple's renderer method cannot be intercepted.
BOOL NuvioFrameTapStart(AVSampleBufferVideoRenderer *renderer,
                        NuvioFrameTapHandler handler);

/// Set to -1 when paused, seeking, or the HDMI display is switching.
/// Target positions are sampled in two-second buckets.
void NuvioFrameTapSetPlaybackSecond(int64_t mediaSecond);
void NuvioFrameTapStop(void);

/// Diagnostic counts: number of renderer enqueues seen / images converted.
uint64_t NuvioFrameTapEnqueueCount(void);
uint64_t NuvioFrameTapImageCount(void);

NS_ASSUME_NONNULL_END
