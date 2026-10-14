#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes a thumbnail locally from an HTTP(S) stream using the FFmpeg
/// demuxers/codecs already linked into MPVKit. Nothing is uploaded.
FOUNDATION_EXPORT UIImage * _Nullable NuvioDecodedThumbnail(NSURL *url,
    int64_t seconds, double timeoutSeconds);

NS_ASSUME_NONNULL_END
