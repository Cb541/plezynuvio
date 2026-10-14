import AVFoundation
import Foundation
import UIKit

/// On-device FFmpeg thumbnail decoder for HTTP Matroska/HEVC and compatible
/// videos. The latest requested preview position wins, without starving the
/// visible image when a held Siri Remote button advances faster than a
/// network GOP can be decoded.
///
/// Inspired by Cine's quick-keyframe seeking: decode the nearest usable
/// random-access picture rather than making the preview renderer chase
/// every intermediate frame. Video data and signed URLs remain on-device.
final class SeekFrameService {
    private struct Request {
        let url: URL
        let second: Int
        let callback: (UIImage?) -> Void
    }

    private let worker = DispatchQueue(label: "com.cb541.nuvio.seek-frames", qos: .userInitiated)
    private let decoder = NuvioThumbnailDecoder()
    private let lock = NSLock()
    private var cache: [Int: UIImage] = [:]
    private var cacheOrder: [Int] = []
    private var generation: UInt64 = 0
    private var isWorkerRunning = false
    private var pending: Request?
    private var activeToken: NuvioThumbnailAbortToken?

    func cancel() {
        lock.lock()
        generation &+= 1
        activeToken?.cancelled = true
        pending = nil
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation &+= 1
        activeToken?.cancelled = true
        pending = nil
        cache.removeAll()
        cacheOrder.removeAll()
        lock.unlock()
        worker.async { [weak self] in self?.decoder.reset() }
    }

    /// Request just ONE image above the timeline; while FFmpeg is busy,
    /// replace any pending request with the newest position. Unlike the old
    /// implementation, we don't abort an actively decoding image every
    /// 380ms of a remote long-press, so actual previews can be rendered.
    func request(url: URL, second: Int, callback: @escaping (UIImage?) -> Void) {
        let key = max(0, (second / 5) * 5)
        lock.lock()
        let cached = cache[key]
        let version = generation
        if cached == nil {
            pending = Request(url: url, second: key, callback: callback)
            if !isWorkerRunning {
                isWorkerRunning = true
                worker.async { [weak self] in self?.processRequests() }
            }
        }
        lock.unlock()

        if let cached {
            deliver(cached, version: version, callback: callback)
        }
    }

    private func processRequests() {
        while true {
            lock.lock()
            guard let request = pending else {
                isWorkerRunning = false
                lock.unlock()
                return
            }
            pending = nil
            let version = generation
            let token = NuvioThumbnailAbortToken()
            activeToken = token
            lock.unlock()

            let decoded = decoder.thumbnail(for: request.url,
                second: Int64(request.second), timeoutSeconds: 4.0, token: token)
            let image = decoded ?? (token.cancelled ? nil
                : appleFallback(url: request.url, second: request.second))

            lock.lock()
            let valid = generation == version && !token.cancelled
            let waitingForNewerFrame = pending != nil
            if valid, let image {
                cache[request.second] = image
                cacheOrder.removeAll { $0 == request.second }
                cacheOrder.append(request.second)
                while cacheOrder.count > 36 {
                    let oldest = cacheOrder.removeFirst()
                    cache.removeValue(forKey: oldest)
                }
            }
            if activeToken === token { activeToken = nil }
            lock.unlock()

            // Even when a newer seek is queued, display this completed image
            // rather than a permanent placeholder. The next iteration jumps
            // directly to the latest target; intermediate frames are dropped.
            if valid && (image != nil || !waitingForNewerFrame) {
                deliver(image, version: version, callback: request.callback)
            }
        }
    }

    private func deliver(
        _ image: UIImage?,
        version: UInt64,
        callback: @escaping (UIImage?) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillValid = self.generation == version
            self.lock.unlock()
            if stillValid { callback(image) }
        }
    }

    private func appleFallback(url: URL, second: Int) -> UIImage? {
        let extensionName = url.pathExtension.lowercased()
        guard ["m3u8", "mp4", "mov", "m4v"].contains(extensionName) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: Double(second), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: frame)
    }
}
