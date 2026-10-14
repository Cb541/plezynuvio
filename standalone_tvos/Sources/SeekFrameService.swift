import AVFoundation
import CryptoKit
import Foundation
import UIKit

/// Independent, serial thumbnail decoder with a persistent, disk-backed
/// per-stream cache. No fixed cap is placed on stored thumbnails. The small
/// NSCache is only a RAM hot set; tvOS controls available disk space and may
/// evict files from its system Caches directory.
final class SeekFrameService {
    private struct Request {
        let url: URL
        let second: Int
        let prefetch: Bool
        let callback: ((UIImage?) -> Void)?
    }

    private let worker = DispatchQueue(label: "com.cb541.nuvio.seek-frames", qos: .utility)
    private let diskWriter = DispatchQueue(label: "com.cb541.nuvio.seek-disk", qos: .utility)
    private let decoder = NuvioThumbnailDecoder()
    private let lock = NSLock()
    private let hotImages = NSCache<NSString, UIImage>()
    private var generation: UInt64 = 0
    private var isWorkerRunning = false
    private var pending: Request?
    private var pendingBackground: Request?
    private var activeToken: NuvioThumbnailAbortToken?
    private var activeWasBackground = false
    private var scopedDirectory: URL?
    private var sourceKey: String?

    init() {
        // RAM is bounded to protect playback; the persistent disk cache
        // has no application-imposed frame-count or size limit.
        hotImages.totalCostLimit = 24 * 1_024 * 1_024
    }

    private func bucket(_ second: Int) -> Int {
        max(0, (second / 2) * 2)
    }

    private func key(_ second: Int) -> NSString {
        String(bucket(second)) as NSString
    }

    func prepare(url: URL) {
        let identity = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory,
            in: .userDomainMask)[0].appendingPathComponent("NuvioSeekFrames",
                                                          isDirectory: true)
        let dir = root.appendingPathComponent(identity, isDirectory: true)
        lock.lock()
        generation &+= 1
        activeToken?.cancelled = true
        pending = nil
        pendingBackground = nil
        sourceKey = identity
        scopedDirectory = dir
        hotImages.removeAllObjects()
        lock.unlock()
        diskWriter.async {
            try? FileManager.default.createDirectory(at: dir,
                withIntermediateDirectories: true)
        }
        worker.async { [weak self] in self?.decoder.reset() }
    }

    /// Main-thread-safe in-memory lookup for instantaneous swipe feedback.
    /// Disk hits are fetched on the decoder queue, never on the UI thread.
    func cachedImage(second: Int) -> UIImage? {
        hotImages.object(forKey: key(second))
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        activeToken?.cancelled = true
        pending = nil
        pendingBackground = nil
        lock.unlock()
    }

    /// Finish all queued FFmpeg work before mpv seeks the main movie.
    func cancelAndDrain(_ completion: @escaping () -> Void) {
        cancel()
        worker.async { [weak self] in
            self?.decoder.reset()
            DispatchQueue.main.async(execute: completion)
        }
    }

    func clear() {
        cancel()
        lock.lock()
        sourceKey = nil
        scopedDirectory = nil
        hotImages.removeAllObjects()
        lock.unlock()
        worker.async { [weak self] in self?.decoder.reset() }
        // Intentionally DO NOT delete stored previews.
    }

    func request(url: URL, second: Int, callback: @escaping (UIImage?) -> Void) {
        let slot = bucket(second)
        if let cached = hotImages.object(forKey: key(slot)) {
            DispatchQueue.main.async { callback(cached) }
            return
        }
        lock.lock()
        let request = Request(url: url, second: slot,
                              prefetch: false, callback: callback)
        pending = request
        // A foreground preview always supersedes any background decode.
        if activeWasBackground { activeToken?.cancelled = true }
        scheduleWorkerLocked()
        lock.unlock()
    }

    /// Opportunistically generate one thumbnail near playback. Uses the
    /// same serial decoder and is always lower priority than user seeking.
    func prefetch(url: URL, second: Int) {
        let slot = bucket(second)
        if hotImages.object(forKey: key(slot)) != nil { return }
        lock.lock()
        if pending == nil, pendingBackground == nil {
            pendingBackground = Request(url: url, second: slot,
                                        prefetch: true, callback: nil)
            scheduleWorkerLocked()
        }
        lock.unlock()
    }

    private func scheduleWorkerLocked() {
        if !isWorkerRunning {
            isWorkerRunning = true
            worker.async { [weak self] in self?.processRequests() }
        }
    }

    private func diskURL(for slot: Int, directory: URL?) -> URL? {
        directory?.appendingPathComponent("frame-\(slot).jpg")
    }

    private func readDisk(slot: Int, directory: URL?) -> UIImage? {
        guard let file = diskURL(for: slot, directory: directory),
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    private func remember(_ image: UIImage, slot: Int,
                          directory: URL?, writeToDisk: Bool) {
        let pixels = Int(image.size.width * image.size.height * 4)
        hotImages.setObject(image, forKey: key(slot), cost: max(1, pixels))
        guard writeToDisk,
              let file = diskURL(for: slot, directory: directory) else { return }
        // JPEG encode immediately on the serial decoder worker. An unlimited
        // backlog of disk-writing closures retaining full UIImage buffers
        // could otherwise trigger tvOS memory termination while scrubbing.
        guard let bytes = image.jpegData(compressionQuality: 0.8) else { return }
        diskWriter.async {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: file.path) else { return }
            try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? bytes.write(to: file, options: .atomic)
        }
    }

    private func processRequests() {
        while true {
            lock.lock()
            guard let job = pending ?? pendingBackground else {
                isWorkerRunning = false
                activeToken = nil
                activeWasBackground = false
                lock.unlock()
                return
            }
            if pending != nil { pending = nil } else { pendingBackground = nil }
            let version = generation
            let directory = scopedDirectory
            let token = NuvioThumbnailAbortToken()
            activeToken = token
            activeWasBackground = job.prefetch
            lock.unlock()

            let cached = hotImages.object(forKey: key(job.second))
                ?? readDisk(slot: job.second, directory: directory)
            let decoded: UIImage?
            if let cached {
                decoded = cached
            } else if token.cancelled {
                decoded = nil
            } else {
                decoded = decoder.thumbnail(for: job.url,
                    second: Int64(job.second),
                    timeoutSeconds: job.prefetch ? 3.0 : 6.0,
                    token: token)
                    ?? (token.cancelled || job.prefetch ? nil
                        : appleFallback(url: job.url, second: job.second))
            }

            lock.lock()
            let valid = generation == version && !token.cancelled
            let foregroundWaiting = pending != nil
            if activeToken === token { activeToken = nil }
            activeWasBackground = false
            lock.unlock()

            if valid, let image = decoded {
                remember(image, slot: job.second, directory: directory,
                         writeToDisk: cached == nil)
            }
            if valid, !job.prefetch, !foregroundWaiting,
               let callback = job.callback {
                deliver(decoded, version: version, callback: callback)
            }
        }
    }

    private func deliver(_ image: UIImage?, version: UInt64,
                         callback: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.generation == version
            self.lock.unlock()
            if valid { callback(image) }
        }
    }

    private func appleFallback(url: URL, second: Int) -> UIImage? {
        let suffix = url.pathExtension.lowercased()
        guard !["mkv", "webm", "avi", "ts", "m2ts", "vob"].contains(suffix)
            else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: Double(second), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: frame)
    }
}
