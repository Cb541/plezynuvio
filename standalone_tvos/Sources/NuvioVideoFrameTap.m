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
    if (atomic_load_explicit(&sIsPaused, memory_order_acquire))
        return;
    int64_t second = atomic_load_explicit(&sMediaSecond, memory_order_acquire);
    if (second < 0 || !sample)
        return;

    int64_t anchor = atomic_load_explicit(&sAnchorNs, memory_order_relaxed);
    if (anchor > 0) {
        int64_t elapsed = (nuvio_host_ns() - anchor) / 1000000000LL;
        // A delayed main runloop must not pin playback thumbnails to a
        // single timestamp. Extrapolate while video samples keep arriving.
        // If playback stalls there are no new decoded sample callbacks.
        if (elapsed > 0 && elapsed < 86400)
            second += elapsed;
    }
    int64_t slot = (second / 2) * 2;
    if (atomic_load_explicit(&sLastSlot, memory_order_relaxed) == slot)
        return;

    bool available = false;
    if (!atomic_compare_exchange_strong_explicit(&sInFlight, &available, true,
               memory_order_acq_rel, memory_order_relaxed))
        return;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
    if (!imageBuffer) {
        atomic_fetch_add_explicit(&sMissingPixelCount, 1, memory_order_relaxed);
        atomic_store(&sInFlight, false);
        return;
    }
    CVPixelBufferRef retained = (CVPixelBufferRef)imageBuffer;
    CVPixelBufferRetain(retained);
    uint64_t generation = atomic_load(&sGeneration);
    atomic_store(&sLastSlot, slot);

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
                CGColorSpaceRef srgb = CGColorSpaceCreateDeviceRGB();
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
    atomic_store(&sIsPaused, true);
    atomic_store(&sMediaSecond, -1);
    atomic_store(&sAnchorNs, 0);
    atomic_store(&sLastSlot, -1);
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
    if (atomic_load_explicit(&sIsPaused, memory_order_relaxed))
        return;
    if (second < 0) {
        atomic_store_explicit(&sMediaSecond, -1, memory_order_release);
        atomic_store(&sAnchorNs, 0);
        atomic_store(&sLastSlot, -1);
        return;
    }

    // Do not reset the elapsed-time anchor on every quarter-second UI tick.
    // Only a genuine progress update or seek reanchors this clock. Repeated
    // stale time-pos events therefore cannot suppress continuous capture.
    int64_t previous = atomic_load_explicit(&sMediaSecond, memory_order_relaxed);
    if (previous != second) {
        atomic_store(&sAnchorNs, nuvio_host_ns());
        atomic_store_explicit(&sMediaSecond, second, memory_order_release);
    }
}

void NuvioFrameTapSetPaused(BOOL paused)
{
    bool old = atomic_exchange_explicit(&sIsPaused, !!paused,
                                         memory_order_acq_rel);
    if (old == !!paused)
        return;

    // Starting playback afresh must not extrapolate from the time a
    // paused frame was shown minutes earlier. The next mpv time-pos event
    // will provide a new media timestamp and anchor.
    atomic_store(&sMediaSecond, -1);
    atomic_store(&sAnchorNs, 0);
    atomic_store(&sLastSlot, -1);
}

void NuvioFrameTapStop(void)
{
    atomic_store_explicit(&sTargetRenderer, 0, memory_order_release);
    atomic_store_explicit(&sTargetLayer, 0, memory_order_release);
    atomic_store(&sIsPaused, true);
    atomic_store(&sMediaSecond, -1);
    atomic_store(&sAnchorNs, 0);
    atomic_store(&sLastSlot, -1);
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
