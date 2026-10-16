#import <UIKit/UIKit.h>
#import "NuvioVideoFrameTap.h"

NS_ASSUME_NONNULL_BEGIN

/// Decodes a thumbnail locally from an HTTP(S) stream using the FFmpeg
/// demuxers/codecs already linked into MPVKit. Nothing is uploaded.
/// Cancels network demux reads as soon as the Siri Remote moves the
/// preview playhead, rather than waiting several seconds on obsolete frames.
@interface NuvioThumbnailAbortToken : NSObject
@property (atomic, assign) BOOL cancelled;
@end

/// One FFmpeg demuxer/decoder reused across nearby seek preview positions,
/// dramatically reducing repeated Matroska probing and HTTP handshakes.
/// Always call on a single serial queue; reset only on that queue.
@interface NuvioThumbnailDecoder : NSObject
- (nullable UIImage *)thumbnailForURL:(NSURL *)url
                                second:(int64_t)seconds
                        timeoutSeconds:(double)timeoutSeconds
                                 token:(NuvioThumbnailAbortToken *)token;
/// Only use on the low-priority background worker. Decodes a nearest
/// independent keyframe, with bounded reference-decoding fallback for open GOPs.
/// Cancellation and timeouts apply to both paths.
- (nullable UIImage *)keyframeThumbnailForURL:(NSURL *)url
                                        second:(int64_t)seconds
                                timeoutSeconds:(double)timeoutSeconds
                                         token:(NuvioThumbnailAbortToken *)token;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
