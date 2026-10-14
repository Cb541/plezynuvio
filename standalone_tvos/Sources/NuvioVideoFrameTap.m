#import "NuvioVideoFrameTap.h"
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

/// Capture the sample that mpv's AVFoundation VO has *already decoded*
/// just as it enters Apple's video renderer. This app-only hook never changes
/// sample timestamps, the Dolby Vision RPU/attachments or HDMI presentation.
/// Never run Core Image or JPEG conversion on the video enqueue thread.

static os_unfair_lock sHandlerLock = OS_UNFAIR_LOCK_INIT;
static NuvioFrameTapHandler sHandler = nil;
static Class sHookedClass = Nil;
static IMP sOriginalEnqueue = NULL;
static atomic_uintptr_t sTargetRenderer;
static atomic_int_fast64_t sPlaybackSecond;
static atomic_int_fast64_t sLastBucket;
static atomic_uint_fast64_t sGeneration;
static atomic_uint_fast64_t sEnqueueCount;
static atomic_uint_fast64_t sImageCount;
static atomic_bool sInFlight;
static dispatch_queue_t sImageQueue;

static void nuvio_enqueued_sample(id receiver, SEL selector, CMSampleBufferRef sample)
{
    // Absolutely always allow AVFoundation's original renderer to run.
    ((void (*)(id, SEL, CMSampleBufferRef))sOriginalEnqueue)(
        receiver, selector, sample);

    if ((uintptr_t)(__bridge void *)receiver !=
        atomic_load_explicit(&sTargetRenderer, memory_order_acquire))
        return;

    atomic_fetch_add_explicit(&sEnqueueCount, 1, memory_order_relaxed);
    int64_t second = atomic_load_explicit(&sPlaybackSecond, memory_order_relaxed);
    if (second < 0 || !sample)
        return;

    int64_t bucket = (second / 2) * 2;
    if (atomic_load_explicit(&sLastBucket, memory_order_relaxed) == bucket)
        return;
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&sInFlight, &expected, true,
                                                  memory_order_acq_rel,
                                                  memory_order_relaxed))
        return;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
    if (!imageBuffer) {
        atomic_store(&sInFlight, false);
        return;
    }
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)imageBuffer;
    CVPixelBufferRetain(pixelBuffer);
    atomic_store_explicit(&sLastBucket, bucket, memory_order_relaxed);
    uint64_t generation = atomic_load(&sGeneration);

    // Only the retained pixel buffer escapes the video renderer callback.
    dispatch_async(sImageQueue, ^{
        @autoreleasepool {
            if (generation != atomic_load(&sGeneration)) {
                CVPixelBufferRelease(pixelBuffer);
                atomic_store(&sInFlight, false);
                return;
            }

            static CIContext *context;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                context = [CIContext contextWithOptions:@{
                    kCIContextUseSoftwareRenderer: @NO
                }];
            });

            UIImage *thumbnail = nil;
            CIImage *source = [CIImage imageWithCVPixelBuffer:pixelBuffer];
            if (source && !CGRectIsEmpty(source.extent)) {
                CGFloat width = CGRectGetWidth(source.extent);
                CGFloat height = CGRectGetHeight(source.extent);
                CGFloat scale = MIN(1.0, 720.0 / MAX(width, height));
                CIImage *small = [source imageByApplyingTransform:
                    CGAffineTransformMakeScale(scale, scale)];
                CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
                CGImageRef cg = [context createCGImage:small
                                             fromRect:small.extent
                                               format:kCIFormatRGBA8
                                           colorSpace:rgb];
                if (rgb) CGColorSpaceRelease(rgb);
                if (cg) {
                    thumbnail = [UIImage imageWithCGImage:cg];
                    CGImageRelease(cg);
                }
            }
            CVPixelBufferRelease(pixelBuffer);
            atomic_store(&sInFlight, false);

            if (!thumbnail || generation != atomic_load(&sGeneration))
                return;
            atomic_fetch_add(&sImageCount, 1);
            os_unfair_lock_lock(&sHandlerLock);
            NuvioFrameTapHandler callback = [sHandler copy];
            os_unfair_lock_unlock(&sHandlerLock);
            if (!callback)
                return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation == atomic_load(&sGeneration)) {
                    callback(thumbnail, bucket);
                }
            });
        }
    });
}

BOOL NuvioFrameTapStart(AVSampleBufferVideoRenderer *renderer,
                        NuvioFrameTapHandler handler)
{
    if (!renderer || !handler)
        return NO;

    static dispatch_once_t queueOnce;
    dispatch_once(&queueOnce, ^{
        sImageQueue = dispatch_queue_create("com.cb541.nuvio.frame-tap",
                                           DISPATCH_QUEUE_SERIAL);
    });

    Class cls = object_getClass(renderer);
    SEL selector = @selector(enqueueSampleBuffer:);
    Method originalMethod = class_getInstanceMethod(cls, selector);
    if (!originalMethod)
        return NO;

    // Hook only the concrete renderer class used by this one application.
    // Never swizzle again on each newly opened movie.
    @synchronized([AVSampleBufferVideoRenderer class]) {
        if (!sHookedClass) {
            IMP original = method_getImplementation(originalMethod);
            if (!original || original == (IMP)nuvio_enqueued_sample)
                return NO;
            const char *types = method_getTypeEncoding(originalMethod);
            if (!types)
                return NO;
            sOriginalEnqueue = original;
            class_replaceMethod(cls, selector, (IMP)nuvio_enqueued_sample, types);
            sHookedClass = cls;
        } else if (sHookedClass != cls) {
            // An unexpected private renderer class means no safe hook.
            return NO;
        }
    }

    NuvioFrameTapStop();
    os_unfair_lock_lock(&sHandlerLock);
    sHandler = [handler copy];
    os_unfair_lock_unlock(&sHandlerLock);
    atomic_store(&sEnqueueCount, 0);
    atomic_store(&sImageCount, 0);
    atomic_store(&sLastBucket, -1);
    atomic_store(&sPlaybackSecond, -1);
    atomic_store_explicit(&sTargetRenderer, (uintptr_t)(__bridge void *)renderer,
                          memory_order_release);
    NSLog(@"[NuvioCache] Renderer frame tap installed");
    return YES;
}

void NuvioFrameTapSetPlaybackSecond(int64_t mediaSecond)
{
    if (mediaSecond < 0) {
        atomic_store(&sPlaybackSecond, -1);
        atomic_store(&sLastBucket, -1);
        return;
    }
    atomic_store(&sPlaybackSecond, mediaSecond);
}

void NuvioFrameTapStop(void)
{
    atomic_store_explicit(&sTargetRenderer, 0, memory_order_release);
    atomic_store(&sPlaybackSecond, -1);
    atomic_store(&sLastBucket, -1);
    atomic_fetch_add(&sGeneration, 1);
    os_unfair_lock_lock(&sHandlerLock);
    sHandler = nil;
    os_unfair_lock_unlock(&sHandlerLock);
}

uint64_t NuvioFrameTapEnqueueCount(void)
{
    return atomic_load(&sEnqueueCount);
}

uint64_t NuvioFrameTapImageCount(void)
{
    return atomic_load(&sImageCount);
}
