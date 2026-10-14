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

@implementation NuvioThumbnailAbortToken
@end

typedef struct {
    CFAbsoluteTime deadline;
    __unsafe_unretained NuvioThumbnailAbortToken *token;
} NuvioReadDeadline;

static int nuvioInterrupt(void *opaque) {
    if (!opaque) return 1;
    NuvioReadDeadline *state = (NuvioReadDeadline *)opaque;
    return state->token.cancelled || CFAbsoluteTimeGetCurrent() > state->deadline;
}

// Detect letterbox rows embedded into a decoded frame. scaleAspectFill
// handles differing aspect ratios, but source-encoded black bars would
// otherwise remain visible on a full-screen scrubbing preview. Crop only
// a substantial, uniformly black top AND bottom band; don't crop a
// genuinely dark scene merely because its outermost pixels are dim.
static bool nuvioIsBlackBandRow(const uint8_t *pixels, int stride, int width, int row) {
    const uint8_t *line = pixels + (size_t)row * stride;
    for (int sample = 1; sample <= 24; ++sample) {
        int x = (width * sample) / 25;
        const uint8_t *pixel = line + (size_t)x * 4;
        if (pixel[0] > 14 || pixel[1] > 14 || pixel[2] > 14) return false;
    }
    return true;
}

static UIImage *nuvioMakeImage(AVFrame *frame) {
    if (!frame || frame->width <= 0 || frame->height <= 0) return nil;

    // A 640px preview comfortably fills the 432pt floating window, with
    // much lower scaling/retained-image cost than 800px frames.
    const int width = 640;
    const int height = MAX(2, (int)lrint((double)frame->height * width / frame->width) & ~1);
    if (height > 1200) return nil;
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

    int top = 0;
    while (top < height / 3 && nuvioIsBlackBandRow(pixels, stride, width, top)) ++top;
    int bottom = height - 1;
    while (bottom > height * 2 / 3 &&
           nuvioIsBlackBandRow(pixels, stride, width, bottom)) --bottom;

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
    if (top > height / 20 && bottom < height - height / 20) {
        CGRect crop = CGRectMake(0, top, width, bottom - top + 1);
        CGImageRef cropped = CGImageCreateWithImageInRect(cg, crop);
        if (cropped) {
            image = [UIImage imageWithCGImage:cropped];
            CGImageRelease(cropped);
        }
    }
    CGImageRelease(cg);
    return image;
}

// This object lives on the SeekFrameService's private serial worker.
// Keeping the demuxer, codec and existing HTTP connection alive avoids
// re-probing multi-gigabyte MKV files after every Siri Remote movement.
@implementation NuvioThumbnailDecoder {
    AVFormatContext *_format;
    AVCodecContext *_decoder;
    AVPacket *_packet;
    AVFrame *_frame;
    int _streamIndex;
    NSString *_sourceURL;
}

- (void)reset {
    av_frame_free(&_frame);
    av_packet_free(&_packet);
    avcodec_free_context(&_decoder);
    if (_format) {
        _format->interrupt_callback.opaque = NULL;
        avformat_close_input(&_format);
    }
    _format = NULL;
    _streamIndex = -1;
    _sourceURL = nil;
}

- (void)dealloc {
    [self reset];
}

- (nullable UIImage *)thumbnailForURL:(NSURL *)url
                                second:(int64_t)seconds
                        timeoutSeconds:(double)timeoutSeconds
                                 token:(NuvioThumbnailAbortToken *)token {
    @autoreleasepool {
        if (token.cancelled || !url) return nil;
        NSString *scheme = url.scheme.lowercaseString;
        if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return nil;

        // Opening/probing signed HTTP sources can take longer than a single
        // keyframe decode, even for a tiny file. The old shared 5s budget
        // expired during probing, permanently leaving ordinary HEVC black.
        // Use separate cancellable stages; never block the main/UI thread.
        NuvioReadDeadline deadline = {
            .deadline = CFAbsoluteTimeGetCurrent() + MAX(8.0, timeoutSeconds + 3.0),
            .token = token
        };
        if (!_format || ![_sourceURL isEqualToString:url.absoluteString]) {
            [self reset];
            _format = avformat_alloc_context();
            if (!_format) return nil;
            _format->interrupt_callback.callback = nuvioInterrupt;
            _format->interrupt_callback.opaque = &deadline;

            AVDictionary *options = NULL;
            av_dict_set(&options, "rw_timeout", "5500000", 0);
            int rc = avformat_open_input(&_format, url.absoluteString.UTF8String,
                                         NULL, &options);
            av_dict_free(&options);
            if (rc < 0 || !_format || token.cancelled) {
                if (!token.cancelled) NSLog(@"[NuvioPreview] demux-open failed: %d", rc);
                [self reset]; return nil;
            }
            // MP4/MKV often expose their video codec parameters directly
            // after opening. Avoid a lengthy full-stream probe unless needed.
            _streamIndex = av_find_best_stream(_format, AVMEDIA_TYPE_VIDEO,
                                                -1, -1, NULL, 0);
            if (_streamIndex < 0 ||
                _format->streams[_streamIndex]->codecpar->codec_id == AV_CODEC_ID_NONE) {
                if (avformat_find_stream_info(_format, NULL) < 0 || token.cancelled) {
                    if (!token.cancelled)
                        NSLog(@"[NuvioPreview] video probe failed");
                    [self reset]; return nil;
                }
                _streamIndex = av_find_best_stream(_format, AVMEDIA_TYPE_VIDEO,
                                                   -1, -1, NULL, 0);
            }
            if (_streamIndex < 0 || token.cancelled) {
                [self reset]; return nil;
            }
            AVStream *sourceStream = _format->streams[_streamIndex];
            const AVCodec *codec = avcodec_find_decoder(sourceStream->codecpar->codec_id);
            if (!codec) {
                [self reset]; return nil;
            }
            _decoder = avcodec_alloc_context3(codec);
            if (!_decoder || avcodec_parameters_to_context(_decoder,
                    sourceStream->codecpar) < 0) {
                [self reset]; return nil;
            }
            // HEVC Main/Main10 and open-GOP streams commonly need full
            // reference decoding before ANY displayable frame is emitted.
            // The previous NONREF mode often yielded zero frames, and the
            // fallback ran only after the shared network deadline expired.
            _decoder->thread_count = 1;
            _decoder->skip_frame = sourceStream->codecpar->codec_id == AV_CODEC_ID_HEVC
                ? AVDISCARD_DEFAULT : AVDISCARD_NONREF;
            _decoder->skip_loop_filter = AVDISCARD_ALL;
            _decoder->flags2 |= AV_CODEC_FLAG2_FAST;
            if (avcodec_open2(_decoder, codec, NULL) < 0) {
                [self reset]; return nil;
            }
            _packet = av_packet_alloc();
            _frame = av_frame_alloc();
            if (!_packet || !_frame) {
                [self reset]; return nil;
            }
            _sourceURL = [url.absoluteString copy];
        }

        // Previous call's callback pointed at its stack-local deadline.
        // Rebind it for EVERY seek/read and clear before returning.
        _format->interrupt_callback.callback = nuvioInterrupt;
        _format->interrupt_callback.opaque = &deadline;
        // Refresh the budget after open/probe, so fallback decoding is not
        // starved by HTTP negotiation time on small remote files.
        deadline.deadline = CFAbsoluteTimeGetCurrent() + MAX(5.0, timeoutSeconds);
        AVStream *stream = _format->streams[_streamIndex];
        int64_t target = av_rescale_q(MAX(0, seconds), (AVRational){1, 1},
                                      stream->time_base);
        // Some TS/MKV tracks start at nonzero PTS. A timestamp of seconds
        // from the start must include that origin to seek the correct GOP.
        if (stream->start_time != AV_NOPTS_VALUE &&
            stream->start_time > 0 && target <= INT64_MAX - stream->start_time) {
            target += stream->start_time;
        }
        // avformat_seek_file does not honor AVSEEK_FLAG_BACKWARD and the
        // old min_ts=max_ts=target constraint can miss the preceding GOP.
        // av_seek_frame is the API that explicitly seeks to a keyframe.
        int seekResult = av_seek_frame(_format, _streamIndex, target,
                                       AVSEEK_FLAG_BACKWARD);
        if (seekResult < 0)
            seekResult = avformat_seek_file(_format, _streamIndex, INT64_MIN,
                                           target, INT64_MAX, 0);
        if (seekResult < 0 || token.cancelled) {
            if (!token.cancelled) NSLog(@"[NuvioPreview] network seek failed: %d", seekResult);
            [self reset]; return nil;
        }
        avcodec_flush_buffers(_decoder);

        UIImage *image = nil;
        // First attempt: decode a reference picture near the target.
        // On streams that cannot produce one, retry one GOP using normal
        // decoding instead of leaving a permanent black preview.
        for (int pass = 0; pass < 2 && !token.cancelled; ++pass) {
            if (pass == 1) {
                // If a demuxer's indexed seek lands on an open-GOP picture,
                // go several seconds earlier and decode full references.
                // Some small HEVC encodes use few or irregular keyframes.
                if (CFAbsoluteTimeGetCurrent() >= deadline.deadline) break;
                _decoder->skip_frame = AVDISCARD_DEFAULT;
                int64_t rewindTicks = av_rescale_q(5, (AVRational){1, 1},
                                                    stream->time_base);
                int64_t firstTimestamp = stream->start_time != AV_NOPTS_VALUE
                    ? MAX(0, stream->start_time) : 0;
                int64_t retryTarget = MAX(firstTimestamp, target - rewindTicks);
                int retrySeek = av_seek_frame(_format, _streamIndex, retryTarget,
                                              AVSEEK_FLAG_BACKWARD);
                if (retrySeek < 0)
                    retrySeek = avformat_seek_file(_format, _streamIndex,
                                                  INT64_MIN, retryTarget, INT64_MAX, 0);
                if (retrySeek < 0) break;
                avcodec_flush_buffers(_decoder);
            }
            int videoPackets = 0;
            const int packetBudget = pass == 0 ? 140 : 180;
            while (!token.cancelled &&
                   CFAbsoluteTimeGetCurrent() < deadline.deadline &&
                   videoPackets < packetBudget) {
                int readResult = av_read_frame(_format, _packet);
                if (readResult < 0) break;
                if (_packet->stream_index != _streamIndex) {
                    av_packet_unref(_packet);
                    continue;
                }
                ++videoPackets;
                int sent = avcodec_send_packet(_decoder, _packet);
                av_packet_unref(_packet);
                if (sent < 0) continue;
                while (!token.cancelled &&
                       avcodec_receive_frame(_decoder, _frame) == 0) {
                    image = nuvioMakeImage(_frame);
                    av_frame_unref(_frame);
                    if (image) goto finished;
                }
            }
        }

    finished:
        // Keep full reference decoding for HEVC; NONREF caused permanent
        // black boxes on ordinary SDR HEVC files as well as Dolby Vision.
        if (_decoder && stream->codecpar->codec_id != AV_CODEC_ID_HEVC)
            _decoder->skip_frame = AVDISCARD_NONREF;
        _format->interrupt_callback.opaque = NULL;
        if (token.cancelled) {
            [self reset];
            return nil;
        }
        // Keep a fully initialized demuxer across seeks. A failed decode
        // resets the session so a later request can reconnect cleanly.
        if (!image) {
            NSLog(@"[NuvioPreview] no frame: video=%d codec=%d index=%d range=%d; source URL redacted",
                  _streamIndex, stream->codecpar->codec_id, _streamIndex, seekResult);
            [self reset];
        }
        return image;
    }
}
@end
