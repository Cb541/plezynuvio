#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Observes CMSampleBuffers submitted to the app's existing AVFoundation
/// video renderer. No new media decoder, network connection, or seek.
typedef void (^NuvioFrameTapHandler)(UIImage *image, int64_t mediaSecond);

/// Installs one app-local renderer hook. Returns NO without modifying
/// playback when Apple's renderer method cannot be intercepted.
BOOL NuvioFrameTapStart(AVSampleBufferDisplayLayer *layer,
                        AVSampleBufferVideoRenderer *renderer,
                        NuvioFrameTapHandler handler);

/// Rebind after a renderer flush/recreation. Lightweight; safe once per
/// clock tick. The swizzled class handler continues to call Apple's original.
void NuvioFrameTapRefreshTargets(AVSampleBufferDisplayLayer * _Nullable layer,
                                 AVSampleBufferVideoRenderer * _Nullable renderer);

/// Set to -1 when paused, seeking, or the HDMI display is switching.
/// Target positions are sampled in two-second buckets.
void NuvioFrameTapSetPlaybackSecond(int64_t mediaSecond);
// Stop clock extrapolation while mpv is paused; reset timing on resume.
void NuvioFrameTapSetPaused(BOOL paused);
void NuvioFrameTapStop(void);

/// Diagnostic counts: number of renderer enqueues seen / images converted.
uint64_t NuvioFrameTapEnqueueCount(void);
uint64_t NuvioFrameTapImageCount(void);
uint64_t NuvioFrameTapCallbackCount(void);
uint64_t NuvioFrameTapMatchedCount(void);
uint64_t NuvioFrameTapMissingPixelCount(void);
uint64_t NuvioFrameTapConvertFailureCount(void);

/// Read-only DV research probe. Checks whether native decoded pixel buffers
/// carry Apple's per-frame/sequence post-decode HDR metadata. A positive
/// result does not by itself imply a writable or interpretable Dolby RPU.
/// These never modify the image buffer or metadata.
uint64_t NuvioDVProbeSampleCount(void);
uint64_t NuvioDVProbeFrameMetadataBytes(void);
uint64_t NuvioDVProbeSequenceMetadataBytes(void);
uint64_t NuvioDVProbeTaggedSampleCount(void);
/// Exact public attachment keys/types seen by the read-only probe.
NSString *NuvioDVProbeAttachmentSummary(void);

/// Experimental RPU trim editing, OFF by default. Updates existing metadata
/// only, with the original attachment passed through on every error.
void NuvioDVTrimSet(BOOL enabled, double saturation, double contrast, double brightness);
uint64_t NuvioDVTrimEditedCount(void);
int NuvioDVTrimLastTargetCount(void);
uint64_t NuvioDVTrimUneditableCount(void);
BOOL NuvioDVTrimIsEnabled(void);

NS_ASSUME_NONNULL_END
