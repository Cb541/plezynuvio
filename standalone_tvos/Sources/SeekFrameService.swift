import AVFoundation
import Foundation
import UIKit

/// Decodes preview pictures locally from the actual remote stream.
///
/// FFmpeg handles HTTP Matroska/HEVC/Dolby Vision base layers without
/// external servers or thumbnail APIs. AVAssetImageGenerator remains a
/// backup for containers tvOS knows how to open directly.
final class SeekFrameService {
    private let queue = DispatchQueue(label: "com.cb541.nuvio.seek-frames", qos: .userInitiated)
    private let lock = NSLock()
    private var cache: [Int: UIImage] = [:]
    private var cacheOrder: [Int] = []
    private var generation: UInt64 = 0

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation &+= 1
        cache.removeAll()
        cacheOrder.removeAll()
        lock.unlock()
    }

    func request(url: URL, second: Int, callback: @escaping (UIImage?) -> Void) {
        let key = max(0, (second / 15) * 15)
        lock.lock()
        let version = generation
        let image = cache[key]
        lock.unlock()
        if let image {
            DispatchQueue.main.async { callback(image) }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.generation == version
            self.lock.unlock()
            guard valid else { return }

            // A real local decode. Unlike vo=image, this works with FFmpeg
            // sources independently from what mpv's VO was compiled to support.
            let decoded = NuvioDecodedThumbnail(url, Int64(key), 4.3)
            let frame = decoded ?? self.appleFallback(url: url, second: key)

            self.lock.lock()
            let deliver = self.generation == version
            if deliver, let frame {
                self.cache[key] = frame
                self.cacheOrder.removeAll { $0 == key }
                self.cacheOrder.append(key)
                while self.cacheOrder.count > 36 {
                    let oldest = self.cacheOrder.removeFirst()
                    self.cache.removeValue(forKey: oldest)
                }
            }
            self.lock.unlock()
            if deliver { DispatchQueue.main.async { callback(frame) } }
        }
    }

    private func appleFallback(url: URL, second: Int) -> UIImage? {
        // AVFoundation cannot demux an MKV over HTTP, so don't waste a
        // second long timeout on formats only the FFmpeg path understands.
        let extensionName = url.pathExtension.lowercased()
        guard ["m3u8", "mp4", "mov", "m4v"].contains(extensionName) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 340, height: 200)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(
            at: CMTime(seconds: Double(second), preferredTimescale: 600), actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: cg)
    }
}
