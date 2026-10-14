#import "FFmpegThumbnailBridge.h"

// Import only the FFmpeg declarations used here. Importing the generated
// Libavutil umbrella module also imports desktop-only AMF headers, which
// are not shipped for tvOS in this pinned FFmpeg binary distribution.
#include <Libavformat/avformat.h>
#include <Libavcodec/avcodec.h>
#include <Libavcodec/codec_par.h>
#include <Libavutil/avutil.h>
#include <Libavutil/imgutils.h>
#include <Libswscale/swscale.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <limits.h>

typedef struct {
    CFAbsoluteTime deadline;
} NuvioReadDeadline;

static int nuvioInterrupt(void *opaque) {
    if (!opaque) return 1;
    return CFAbsoluteTimeGetCurrent() > ((NuvioReadDeadline *)opaque)->deadline;
}

static UIImage *nuvioMakeImage(AVFrame *frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0) return nil;

    const int width = 340;
    const int height = MAX(2, (int)lrint((double)frame->height * width / frame->width) & ~1);
    if (height > 600) return nil;
    const int stride = width * 4;
    uint8_t *pixels = av_malloc((size_t)stride * height);
    if (!pixels) return nil;
    struct SwsContext *scale = sws_getContext(
        frame->width, frame->height, (enum AVPixelFormat)frame->format,
        width, height, AV_PIX_FMT_BGRA, SWS_BILINEAR,
        NULL, NULL, NULL
    );
    if (!scale) { av_free(pixels); return nil; }

    uint8_t *dst[4] = { pixels, NULL, NULL, NULL };
    int dstStride[4] = { stride, 0, 0, 0 };
    int rows = sws_scale(scale, (const uint8_t *const *)frame->data,
                         frame->linesize, 0, frame->height, dst, dstStride);
    sws_freeContext(scale);
    if (rows <= 0) { av_free(pixels); return nil; }

    NSData *copy = [NSData dataWithBytes:pixels length:(NSUInteger)stride * height];
    av_free(pixels);
    if (!copy) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)copy);
    if (!provider) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(width, height, 8, 32, stride,
        space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    if (!cg) return nil;
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

UIImage *NuvioDecodedThumbnail(NSURL *url, int64_t seconds, double timeoutSeconds) {
    @autoreleasepool {
        if (!url || ![@"http" isEqualToString:url.scheme.lowercaseString] &&
                    ![@"https" isEqualToString:url.scheme.lowercaseString]) return nil;
        NuvioReadDeadline deadline = { .deadline = CFAbsoluteTimeGetCurrent() + MAX(0.5, timeoutSeconds) };
        AVFormatContext *format = avformat_alloc_context();
        if (!format) return nil;
        format->interrupt_callback.callback = nuvioInterrupt;
        format->interrupt_callback.opaque = &deadline;

        AVDictionary *options = NULL;
        av_dict_set(&options, "rw_timeout", "3500000", 0);
        int result = avformat_open_input(&format, url.absoluteString.UTF8String, NULL, &options);
        av_dict_free(&options);
        if (result < 0 || !format) {
            if (format) avformat_close_input(&format);
            return nil;
        }

        UIImage *image = nil;
        AVCodecContext *decoder = NULL;
        AVPacket *packet = NULL;
        AVFrame *frame = NULL;
        if (avformat_find_stream_info(format, NULL) < 0) goto cleanup;
        int streamIndex = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        if (streamIndex < 0) goto cleanup;
        AVStream *stream = format->streams[streamIndex];
        const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
        if (!codec) goto cleanup;
        decoder = avcodec_alloc_context3(codec);
        if (!decoder) goto cleanup;
        if (avcodec_parameters_to_context(decoder, stream->codecpar) < 0) goto cleanup;
        decoder->thread_count = 2;
        decoder->skip_frame = AVDISCARD_NONREF;
        if (avcodec_open2(decoder, codec, NULL) < 0) goto cleanup;
        packet = av_packet_alloc();
        frame = av_frame_alloc();
        if (!packet || !frame) goto cleanup;

        // Fast keyframe seek on the original network stream. MKV, AV1,
        // H.264 and HEVC are handled through FFmpeg, not AVAssetImageGenerator.
        int64_t target = av_rescale_q(MAX(0, seconds), (AVRational){1, 1}, stream->time_base);
        if (seconds > 0) {
            if (avformat_seek_file(format, streamIndex, INT64_MIN, target, target,
                                   AVSEEK_FLAG_BACKWARD) < 0) {
                av_seek_frame(format, streamIndex, target, AVSEEK_FLAG_BACKWARD);
            }
            avcodec_flush_buffers(decoder);
        }

        int videoPackets = 0;
        while (CFAbsoluteTimeGetCurrent() < deadline.deadline && videoPackets < 60) {
            if (av_read_frame(format, packet) < 0) break;
            if (packet->stream_index != streamIndex) {
                av_packet_unref(packet);
                continue;
            }
            videoPackets++;
            int sent = avcodec_send_packet(decoder, packet);
            av_packet_unref(packet);
            if (sent < 0) continue;
            while (avcodec_receive_frame(decoder, frame) == 0) {
                int64_t ts = frame->best_effort_timestamp;
                // Keep the first decoded video frame as an emergency preview,
                // then replace it if decoding approaches the requested time.
                if (!image) image = nuvioMakeImage(frame);
                int64_t tolerance = av_rescale_q(1, (AVRational){1, 1}, stream->time_base);
                if (ts == AV_NOPTS_VALUE || ts >= target - tolerance) {
                    UIImage *nearTarget = nuvioMakeImage(frame);
                    if (nearTarget) image = nearTarget;
                    av_frame_unref(frame);
                    goto cleanup;
                }
                av_frame_unref(frame);
            }
        }

    cleanup:
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&decoder);
        avformat_close_input(&format);
        return image;
    }
}
