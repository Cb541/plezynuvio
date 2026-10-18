#import "NuvioVideoFrameTap.h"
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

// Two known enqueue routes exist: modern AVSampleBufferVideoRenderer and the
// legacy AVSampleBufferDisplayLayer. MPVKit normally uses the modern one, but
// tvOS may replace its renderer when the HDMI/DV display is reconfigured.
// Capture at most one ALREADY-DECODED buffer per two-second slot.
// No additional demuxer, video decoder, remote request or playback seek.

static os_unfair_lock sCallbackLock = OS_UNFAIR_LOCK_INIT;
static NuvioFrameTapHandler sCallback;
static Class sRendererHookClass;
static Class sLayerHookClass;
static IMP sOriginalRendererEnqueue;
static IMP sOriginalLayerEnqueue;

static atomic_uintptr_t sTargetRenderer;
static atomic_uintptr_t sTargetLayer;
static atomic_int_fast64_t sMediaSecond;
static atomic_int_fast64_t sAnchorNs;
static atomic_int_fast64_t sLastSlot;
static atomic_int_fast64_t sLastCapturedPresentationNs;
static atomic_bool sIsPaused;
static atomic_uint_fast64_t sGeneration;
static atomic_uint_fast64_t sEnqueueCount;
static atomic_uint_fast64_t sMatchedCount;
static atomic_uint_fast64_t sMissingPixelCount;
static atomic_uint_fast64_t sImageCount;
static atomic_uint_fast64_t sCallbackCount;
static atomic_uint_fast64_t sConvertFailures;
static atomic_bool sInFlight;
static dispatch_queue_t sConvertQueue;

// Diagnostic only: inspect already-present metadata on decoded video frames.
// Never rewrite any RPU data, pixel buffer, or CMSampleBuffer for playback.
static atomic_uint_fast64_t sDVProbeSamples;
static atomic_uint_fast64_t sDVProbeTaggedSamples;
static atomic_uint_fast64_t sDVProbeFrameBytes;
static atomic_uint_fast64_t sDVProbeSequenceBytes;
static os_unfair_lock sDVProbeSummaryLock = OS_UNFAIR_LOCK_INIT;
static NSString *sDVProbeSummary = @"No matching metadata key";


// Use the monotonic host clock to advance frame-index timestamps when the
// tvOS main runloop or mpv's time-pos observer is temporarily delayed.
// mpv's AVFoundation VO presents video on the HOST timebase in this app,
// so the elapsed host time advances in step with normally played frames.
// No second decoder or separate video request is involved.
static int64_t nuvio_host_ns(void)
{
    return (int64_t)(CACurrentMediaTime() * 1000000000.0);
}

static void nuvio_process_sample(id receiver, CMSampleBufferRef sample, bool viaLayer)
{
    atomic_fetch_add_explicit(&sEnqueueCount, 1, memory_order_relaxed);

    uintptr_t address = (uintptr_t)(__bridge void *)receiver;
    uintptr_t target = viaLayer
        ? atomic_load_explicit(&sTargetLayer, memory_order_acquire)
        : atomic_load_explicit(&sTargetRenderer, memory_order_acquire);
    if (!target || address != target)
        return;

    atomic_fetch_add_explicit(&sMatchedCount, 1, memory_order_relaxed);
    if (!sample)
        return;

    // MPV's AVFoundation VO emits a *host-clock* PTS on each video sample.
    // That advances continuously on the native video-output thread even
    // when the Swift playback timer, pause observer, or seek UI is stale.
    // Sample exactly once every two seconds of *video being enqueued*.
    // The presence of video frames itself is the playback signal.
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    double ptsSeconds = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : NAN;
    int64_t sampleNs = isfinite(ptsSeconds) && ptsSeconds > 0
        && ptsSeconds < (double)INT64_MAX / 1e9
        ? (int64_t)(ptsSeconds * 1000000000.0)
        : nuvio_host_ns();

    int64_t lastPresentation = atomic_load_explicit(
        &sLastCapturedPresentationNs, memory_order_relaxed);
    if (lastPresentation > 0 && sampleNs >= lastPresentation &&
        sampleNs - lastPresentation < 2000000000LL)
        return;

    bool available = false;
    if (!atomic_compare_exchange_strong_explicit(&sInFlight, &available, true,
               memory_order_acq_rel, memory_order_relaxed))
        return;

    // Use mpv's actual time-pos whenever provided; otherwise continue from
    // the native presentation timestamp. A player that starts from 0 should
    // still accumulate frames even if *no* Swift observer fires.
    int64_t second = atomic_load_explicit(&sMediaSecond,
                                           memory_order_relaxed);
    int64_t anchor = atomic_load_explicit(&sAnchorNs,
                                          memory_order_relaxed);
    if (second < 0) {
        second = 0;
        anchor = sampleNs;
        atomic_store_explicit(&sAnchorNs, anchor, memory_order_relaxed);
        atomic_store_explicit(&sMediaSecond, second, memory_order_relaxed);
    } else if (anchor <= 0) {
        anchor = sampleNs;
        atomic_store_explicit(&sAnchorNs, anchor, memory_order_relaxed);
    }
    int64_t elapsed = (sampleNs - anchor) / 1000000000LL;
    if (elapsed > 0 && elapsed < 86400)
        second += elapsed;
    int64_t slot = (MAX(0, second) / 2) * 2;
    if (atomic_load_explicit(&sLastSlot, memory_order_relaxed) == slot) {
        atomic_store_explicit(&sInFlight, false, memory_order_release);
        return;
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
    if (!imageBuffer) {
        atomic_fetch_add_explicit(&sMissingPixelCount, 1, memory_order_relaxed);
        atomic_store(&sInFlight, false);
        return;
    }
    CVPixelBufferRef retained = (CVPixelBufferRef)imageBuffer;
    // tvOS does not expose the macOS-only post-decode processing metadata
    // constants (the tvOS SDK explicitly marks them unavailable). Instead,
    // inspect available *public* Core Video attachment dictionaries for
    // possible RPU/Dolby metadata, once per sampled playback buffer.
    // This is read-only and never modifies the video or its metadata.
    atomic_fetch_add_explicit(&sDVProbeSamples, 1, memory_order_relaxed);
    CFDictionaryRef attachments = CVBufferCopyAttachments(retained,
        kCVAttachmentMode_ShouldPropagate);
    uint64_t frameBytes = 0, sequenceBytes = 0;
    NSMutableArray<NSString *> *matchedKeys = [NSMutableArray array];
    if (attachments) {
        NSDictionary *all = (__bridge NSDictionary *)attachments;
        for (id key in all) {
            NSString *name = [key description];
            NSString *label = [name lowercaseString];
            if ([label containsString:@"dolby"] ||
                [label containsString:@"rpu"] ||
                [label containsString:@"postdecode"] ||
                [label containsString:@"metadata"]) {
                id value = all[key];
                uint64_t bytes = [value isKindOfClass:[NSData class]]
                    ? (uint64_t)[(NSData *)value length] : 0;
                if ([label containsString:@"sequence"])
                    sequenceBytes += bytes;
                else
                    frameBytes += bytes;
                // Only attachment names, object types and lengths are shown.
                // No video data or private metadata payload is logged.
                [matchedKeys addObject:[NSString stringWithFormat:
                    @"%@ [%@, %llu B]", name,
                    NSStringFromClass([value class]),
                    (unsigned long long)bytes]];
            }
        }
        CFRelease(attachments);
    }
    NSString *summary = matchedKeys.count > 0
        ? [matchedKeys componentsJoinedByString:@"; "]
        : @"No matching metadata key";
    os_unfair_lock_lock(&sDVProbeSummaryLock);
    if (![sDVProbeSummary isEqualToString:summary]) {
        sDVProbeSummary = [summary copy];
        NSLog(@"[NuvioDVProbe] attachment key/type: %@", summary);
    }
    os_unfair_lock_unlock(&sDVProbeSummaryLock);
    atomic_store_explicit(&sDVProbeFrameBytes, frameBytes, memory_order_relaxed);
    atomic_store_explicit(&sDVProbeSequenceBytes, sequenceBytes, memory_order_relaxed);
    if (frameBytes || sequenceBytes)
        atomic_fetch_add_explicit(&sDVProbeTaggedSamples, 1, memory_order_relaxed);
    CVPixelBufferRetain(retained);
    uint64_t generation = atomic_load(&sGeneration);
    atomic_store(&sLastSlot, slot);
    atomic_store(&sLastCapturedPresentationNs, sampleNs);

    dispatch_async(sConvertQueue, ^{
        @autoreleasepool {
            if (generation != atomic_load(&sGeneration)) {
                CVPixelBufferRelease(retained);
                atomic_store(&sInFlight, false);
                return;
            }
            static CIContext *ci;
            static dispatch_once_t contextOnce;
            dispatch_once(&contextOnce, ^{
                ci = [CIContext contextWithOptions:@{
                    kCIContextUseSoftwareRenderer: @NO
                }];
            });
            CGImageRef cg = NULL;
            CIImage *input = [CIImage imageWithCVPixelBuffer:retained];
            if (input && !CGRectIsEmpty(input.extent)) {
                CGFloat longer = MAX(input.extent.size.width,
                                     input.extent.size.height);
                CGFloat scale = MIN(1.0, 720.0 / MAX(1.0, longer));
                CIImage *small = [input imageByApplyingTransform:
                    CGAffineTransformMakeScale(scale, scale)];
                // The AVSampleBuffer renderer can expose native PQ/HLG
                // buffers. Explicitly tone map the *thumbnail copy* to SDR;
                // the real video buffer above is never changed.
                CFTypeRef transfer = CVBufferGetAttachment(retained,
                    kCVImageBufferTransferFunctionKey, NULL);
                BOOL hdrTransfer = transfer &&
                    (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                     CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
                if (hdrTransfer) {
                    CIFilter *tone = [CIFilter filterWithName:@"CIToneMapHeadroom"];
                    if (tone && [tone.inputKeys containsObject:@"inputTargetHeadroom"]) {
                        [tone setValue:small forKey:kCIInputImageKey];
                        [tone setValue:@(8.0f) forKey:@"inputSourceHeadroom"];
                        [tone setValue:@(1.0f) forKey:@"inputTargetHeadroom"];
                        if (tone.outputImage) small = tone.outputImage;
                    }
                }
                // A concrete SDR destination also converts the image's
                // tagged color primaries rather than treating PQ as DeviceRGB.
                CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                cg = [ci createCGImage:small fromRect:small.extent
                                  format:kCIFormatRGBA8 colorSpace:srgb];
                CGColorSpaceRelease(srgb);
            }
            if (!cg) {
                // Native VideoToolbox image conversion can succeed where
                // Core Image refuses a 10-bit or unusual hardware surface.
                VTCreateCGImageFromCVPixelBuffer(retained, NULL, &cg);
            }
            CVPixelBufferRelease(retained);
            UIImage *result = cg ? [UIImage imageWithCGImage:cg] : nil;
            if (cg) CGImageRelease(cg);
            atomic_store(&sInFlight, false);

            if (!result) {
                atomic_fetch_add_explicit(&sConvertFailures, 1,
                                          memory_order_relaxed);
                return;
            }
            if (generation != atomic_load(&sGeneration))
                return;
            atomic_fetch_add_explicit(&sImageCount, 1, memory_order_relaxed);
            os_unfair_lock_lock(&sCallbackLock);
            NuvioFrameTapHandler callback = [sCallback copy];
            os_unfair_lock_unlock(&sCallbackLock);
            if (callback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation == atomic_load(&sGeneration)) {
                        atomic_fetch_add_explicit(&sCallbackCount, 1,
                                                  memory_order_relaxed);
                        callback(result, slot);
                    }
                });
            }
        }
    });
}

static void nuvio_renderer_enqueue(id receiver, SEL selector,
                                    CMSampleBufferRef sample)
{
    // Apple's original method always runs. Never block/drop playback frames.
    ((void (*)(id, SEL, CMSampleBufferRef))sOriginalRendererEnqueue)(
        receiver, selector, sample);
    nuvio_process_sample(receiver, sample, false);
}

static void nuvio_layer_enqueue(id receiver, SEL selector,
                                 CMSampleBufferRef sample)
{
    ((void (*)(id, SEL, CMSampleBufferRef))sOriginalLayerEnqueue)(
        receiver, selector, sample);
    nuvio_process_sample(receiver, sample, true);
}

static bool nuvio_install_hook(Class cls, IMP replacement,
                               Class *installedClass, IMP *original)
{
    if (!cls)
        return false;
    if (*installedClass)
        return cls == *installedClass;

    SEL selector = @selector(enqueueSampleBuffer:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method)
        return false;

    IMP existing = method_getImplementation(method);
    const char *encoding = method_getTypeEncoding(method);
    if (!existing || !encoding || existing == replacement)
        return false;

    *original = existing;
    // class_replaceMethod installs on this concrete class, including when
    // enqueueSampleBuffer: is inherited from an Apple AVFoundation superclass.
    class_replaceMethod(cls, selector, replacement, encoding);
    *installedClass = cls;
    return true;
}

BOOL NuvioFrameTapStart(AVSampleBufferDisplayLayer *layer,
                        AVSampleBufferVideoRenderer *renderer,
                        NuvioFrameTapHandler callback)
{
    if (!layer || !callback)
        return NO;
    static dispatch_once_t queueOnce;
    dispatch_once(&queueOnce, ^{
        sConvertQueue = dispatch_queue_create("com.cb541.nuvio.frame-tap",
                                              DISPATCH_QUEUE_SERIAL);
    });

    // Hook the app's MpvVideoLayer (a subclass of AVSampleBufferDisplayLayer)
    // as well as Apple's video renderer. One can be unused without affecting
    // playback; both report independent enqueue counters.
    BOOL layerOK = nuvio_install_hook(object_getClass(layer),
        (IMP)nuvio_layer_enqueue, &sLayerHookClass, &sOriginalLayerEnqueue);
    BOOL rendererOK = renderer && nuvio_install_hook(object_getClass(renderer),
        (IMP)nuvio_renderer_enqueue, &sRendererHookClass,
        &sOriginalRendererEnqueue);
    if (!layerOK && !rendererOK)
        return NO;

    NuvioFrameTapStop();
    os_unfair_lock_lock(&sCallbackLock);
    sCallback = [callback copy];
    os_unfair_lock_unlock(&sCallbackLock);
    atomic_store(&sEnqueueCount, 0);
    atomic_store(&sMatchedCount, 0);
    atomic_store(&sMissingPixelCount, 0);
    atomic_store(&sImageCount, 0);
    atomic_store(&sCallbackCount, 0);
    atomic_store(&sConvertFailures, 0);
    atomic_store(&sDVProbeSamples, 0);
    atomic_store(&sDVProbeTaggedSamples, 0);
    atomic_store(&sDVProbeFrameBytes, 0);
    atomic_store(&sDVProbeSequenceBytes, 0);
    os_unfair_lock_lock(&sDVProbeSummaryLock);
    sDVProbeSummary = @"No matching metadata key";
    os_unfair_lock_unlock(&sDVProbeSummaryLock);
    atomic_store(&sIsPaused, true);
    atomic_store(&sMediaSecond, -1);
    atomic_store(&sAnchorNs, 0);
    atomic_store(&sLastSlot, -1);
    atomic_store(&sLastCapturedPresentationNs, 0);
    NuvioFrameTapRefreshTargets(layer, renderer);
    NSLog(@"[NuvioCache] Frame tap: layer=%d renderer=%d",
          layerOK, rendererOK);
    return YES;
}

void NuvioFrameTapRefreshTargets(AVSampleBufferDisplayLayer *layer,
                                 AVSampleBufferVideoRenderer *renderer)
{
    // Apple's video renderer can change after flush, reconfiguration or
    // HDMI display-mode matching. Keep the actual receiver pointer current.
    if (layer && (!sLayerHookClass ||
                  object_getClass(layer) == sLayerHookClass))
        atomic_store_explicit(&sTargetLayer,
            (uintptr_t)(__bridge void *)layer, memory_order_release);
    if (renderer && (!sRendererHookClass ||
                     object_getClass(renderer) == sRendererHookClass))
        atomic_store_explicit(&sTargetRenderer,
            (uintptr_t)(__bridge void *)renderer, memory_order_release);
}

void NuvioFrameTapSetPlaybackSecond(int64_t second)
{
    if (second < 0) {
        // -1 from a UI update is NOT evidence that native playback has
        // stopped. Never disarm an active stream of video samples.
        return;
    }
    int64_t previous = atomic_load_explicit(&sMediaSecond,
                                            memory_order_relaxed);
    if (previous != second) {
        atomic_store_explicit(&sAnchorNs, nuvio_host_ns(),
                              memory_order_relaxed);
        atomic_store_explicit(&sMediaSecond, second,
                              memory_order_release);
    }
}

void NuvioFrameTapSetPaused(BOOL paused)
{
    bool old = atomic_exchange_explicit(&sIsPaused, !!paused,
                                         memory_order_acq_rel);
    if (old == !!paused)
        return;
    // The native renderer is authoritative. Do not suppress any video sample
    // on the basis of a cached pause flag; mpv's VO stops enqueuing when
    // paused. Reanchor to the next video sample after an actual resume.
    if (!paused) {
        atomic_store(&sAnchorNs, 0);
        atomic_store(&sLastCapturedPresentationNs, 0);
    }
}

void NuvioFrameTapStop(void)
{
    atomic_store_explicit(&sTargetRenderer, 0, memory_order_release);
    atomic_store_explicit(&sTargetLayer, 0, memory_order_release);
    atomic_store(&sIsPaused, true);
    atomic_store(&sMediaSecond, -1);
    atomic_store(&sAnchorNs, 0);
    atomic_store(&sLastSlot, -1);
    atomic_store(&sLastCapturedPresentationNs, 0);
    atomic_fetch_add(&sGeneration, 1);
    os_unfair_lock_lock(&sCallbackLock);
    sCallback = nil;
    os_unfair_lock_unlock(&sCallbackLock);
}

uint64_t NuvioFrameTapEnqueueCount(void) { return atomic_load(&sEnqueueCount); }
uint64_t NuvioFrameTapMatchedCount(void) { return atomic_load(&sMatchedCount); }
uint64_t NuvioFrameTapImageCount(void) { return atomic_load(&sImageCount); }
uint64_t NuvioFrameTapCallbackCount(void) { return atomic_load(&sCallbackCount); }
uint64_t NuvioFrameTapMissingPixelCount(void) { return atomic_load(&sMissingPixelCount); }
uint64_t NuvioFrameTapConvertFailureCount(void) { return atomic_load(&sConvertFailures); }
uint64_t NuvioDVProbeSampleCount(void) { return atomic_load(&sDVProbeSamples); }
uint64_t NuvioDVProbeTaggedSampleCount(void) { return atomic_load(&sDVProbeTaggedSamples); }
uint64_t NuvioDVProbeFrameMetadataBytes(void) { return atomic_load(&sDVProbeFrameBytes); }
uint64_t NuvioDVProbeSequenceMetadataBytes(void) { return atomic_load(&sDVProbeSequenceBytes); }
NSString *NuvioDVProbeAttachmentSummary(void) {
    os_unfair_lock_lock(&sDVProbeSummaryLock);
    NSString *value = [sDVProbeSummary copy];
    os_unfair_lock_unlock(&sDVProbeSummaryLock);
    return value ?: @"No matching metadata key";
}
