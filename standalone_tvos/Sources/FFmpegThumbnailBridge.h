#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes a thumbnail locally from an HTTP(S) stream using the FFmpeg
/// demuxers/codecs already linked into MPVKit. Nothing is uploaded.
/// Cancels network demux reads as soon as the Siri Remote moves the
/// preview playhead, rather than waiting several seconds on obsolete frames.
@interface NuvioThumbnailAbortToken : NSObject
@property (atomic, assign) BOOL cancelled;
@end

FOUNDATION_EXPORT UIImage * _Nullable NuvioDecodedThumbnail(NSURL *url,
    int64_t seconds, double timeoutSeconds, NuvioThumbnailAbortToken *token);

NS_ASSUME_NONNULL_END
