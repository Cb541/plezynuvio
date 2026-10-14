import AVFoundation
import Foundation
import ImageIO
import Libmpv
import UIKit

/// Independent preview engine. Does not seek or reconfigure the playback core.
/// Serialized requests and a small cache bound decoder pressure on Apple TV.
final class SeekFrameService {
    private let worker = DispatchQueue(label: "com.cb541.nuvio.frames", qos: .utility)
    private let lock = NSLock()
    private var cache: [Int: UIImage] = [:]
    private var recentKeys: [Int] = []
    private var generation: UInt64 = 0
    private let maxEntries = 48

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation &+= 1
        cache.removeAll()
        recentKeys.removeAll()
        lock.unlock()
    }

    /// Callback occurs on main. Priority is center frame first, then its neighbors.
    func request(url: URL, second: Int, callback: @escaping (UIImage?) -> Void) {
        let key = max(0, second / 10 * 10)
        lock.lock()
        let current = generation
        if let cached = cache[key] {
            lock.unlock()
            DispatchQueue.main.async { callback(cached) }
            return
        }
        lock.unlock()

        worker.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let obsolete = self.generation != current
            self.lock.unlock()
            guard !obsolete else { return }
            let image = self.extract(url: url, second: key)
                ?? self.assetFallback(url: url, second: key)
            self.lock.lock()
            if let image, self.generation == current {
                self.cache[key] = image
                self.recentKeys.removeAll { $0 == key }
                self.recentKeys.append(key)
                while self.recentKeys.count > self.maxEntries {
                    let oldest = self.recentKeys.removeFirst()
                    self.cache.removeValue(forKey: oldest)
                }
            }
            let usable = self.generation == current
            self.lock.unlock()
            if usable { DispatchQueue.main.async { callback(image) } }
        }
    }

    /// `vo=image` outputs just a still frame into a private temporary folder.
    /// `start` + fast-keyframe seeking avoids downloading the entire file.
    private func extract(url: URL, second: Int) -> UIImage? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvio-seek-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { return nil }
        defer { try? FileManager.default.removeItem(at: dir) }

        guard let mpv = mpv_create() else { return nil }
        defer { mpv_terminate_destroy(mpv) }

        let options: [(String, String)] = [
            ("config", "no"),
            ("vo", "image"),
            ("vo-image-format", "png"),
            ("vo-image-outdir", dir.path),
            ("audio", "no"),
            ("aid", "no"),
            ("sid", "no"),
            ("hwdec", "no"),
            ("start", String(second)),
            ("hr-seek", "no"),
            ("frames", "1"),
            ("cache", "no"),
            ("demuxer-readahead-secs", "0"),
            ("force-window", "no"),
            ("msg-level", "all=error")
        ]
        for (key, value) in options {
            guard mpv_set_option_string(mpv, key, value) >= 0 else { return nil }
        }
        guard mpv_initialize(mpv) >= 0 else { return nil }

        let words = ["loadfile", url.absoluteString, "replace"]
        let owned = words.compactMap { strdup($0) }
        guard owned.count == words.count else {
            for entry in owned { free(entry) }
            return nil
        }
        defer { for entry in owned { free(entry) } }
        var args: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        args.append(nil)
        let rc = args.withUnsafeMutableBufferPointer { mpv_command(mpv, $0.baseAddress) }
        guard rc >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            let event = mpv_wait_event(mpv, 0.10)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for path in files where ["png", "jpg", "jpeg"].contains(path.pathExtension.lowercased()) {
                // An image may still be in the process of being written.
                if let frame = decodeSmallImage(path) { return frame }
            }
            if let event, event.pointee.event_id == MPV_EVENT_END_FILE { break }
        }
        return nil
    }

    private func decodeSmallImage(_ file: URL) -> UIImage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let n = attrs[.size] as? NSNumber, n.intValue > 0, n.intValue < 16_000_000,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// MP4/HLS fallback when `vo=image` cannot initialize; AVFoundation
    /// cannot reliably decode an arbitrary MKV.
    private func assetFallback(url: URL, second: Int) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 220)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: Double(second), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: frame)
    }
}
