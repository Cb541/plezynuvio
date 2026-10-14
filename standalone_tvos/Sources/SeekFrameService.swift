import AVFoundation
import CryptoKit
import Foundation
import UIKit

/// Crash-safe previews use Apple's AVAssetImageGenerator rather than a
/// second unmanaged FFmpeg decoder. The old FFmpeg path terminated tvOS on
/// unrelated codecs and is intentionally NEVER invoked by this service.
/// Unsupported formats fail gracefully; disk-cached previews remain intact.
final class SeekFrameService {
    struct CacheStats {
        let slots: [Int]
        let writeMBPerSecond: Double
        let frameCount: Int
        let deliveredFrames: Int
        let jpegEncodedFrames: Int
        let failedEncodes: Int
        let failedWrites: Int
        let missingDirectories: Int
        let diskBytes: Int64
        let diskFrames: Int
        let ramOnlyFrames: Int
        let storageError: String
    }

    private struct Request {
        let url: URL
        let second: Int
        let prefetch: Bool
        let allowSystemDecode: Bool
        let callback: ((UIImage?) -> Void)?
    }

    private let worker = DispatchQueue(label: "com.cb541.nuvio.seek-frames", qos: .utility)
    private let diskWriter = DispatchQueue(label: "com.cb541.nuvio.seek-disk", qos: .utility)
    private let diskReader = DispatchQueue(label: "com.cb541.nuvio.seek-read",
                                            qos: .userInitiated)
    private let lock = NSLock()
    private let hotImages = NSCache<NSString, UIImage>()
    private var generation: UInt64 = 0
    private var latestCacheLookup: UInt64 = 0
    private var isWorkerRunning = false
    private var pending: Request?
    private var pendingBackground: Request?
    private var activeToken: NuvioThumbnailAbortToken?
    private var activeWasBackground = false
    private var scopedDirectory: URL?
    // Keep older thumbnails readable while new frames live in Application Support.
    private var legacyScopedDirectory: URL?
    private var backgroundPrefetchUnavailable = false
    private var sourceKey: String?
    // Only the compressed JPEGs consume persistent disk; memory remains
    // bounded. These slot indices are loaded once and amended after writes.
    private var cachedSlots = Set<Int>()
    private var recentDiskWrites: [(date: Date, bytes: Int)] = []
    // Keep frame capture entirely separate from the seek/AVAsset worker.
    // In particular, a slow remote seek can no longer prevent frames from
    // an already-playing video from reaching persistent thumbnail storage.
    private var cacheEpoch: UInt64 = 0
    private var deliveredFrames = 0
    private var jpegEncodedFrames = 0
    private var failedEncodes = 0
    private var failedWrites = 0
    private var missingDirectories = 0
    private var diskBytes: Int64 = 0
    // JPEG-compressed RAM fallbacks stay seekable when tvOS rejects file IO.
    // Unlike NSCache<UIImage>, this store has a strict 24 MiB byte budget
    // and removes evicted slots from the reported coverage accurately.
    private var compressedFrames: [Int: Data] = [:]
    private var compressedOrder: [Int] = []
    private var compressedBytes = 0
    private let compressedLimit = 24 * 1_024 * 1_024
    private var lastStorageError = ""

    init() {
        // RAM is bounded to protect playback; the persistent disk cache
        // has no application-imposed frame-count or size limit.
        hotImages.totalCostLimit = 48 * 1_024 * 1_024
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
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("NuvioSeekFrames",
                                                          isDirectory: true)
        let dir = root.appendingPathComponent(identity, isDirectory: true)
        let legacyRoot = fm.urls(for: .cachesDirectory,
            in: .userDomainMask)[0].appendingPathComponent("NuvioSeekFrames",
                                                          isDirectory: true)
        lock.lock()
        generation &+= 1
        cacheEpoch &+= 1
        latestCacheLookup &+= 1
        activeToken?.cancelled = true
        pending = nil
        pendingBackground = nil
        sourceKey = identity
        scopedDirectory = dir
        legacyScopedDirectory = legacyRoot.appendingPathComponent(identity,
                                                                  isDirectory: true)
        backgroundPrefetchUnavailable = false
        cachedSlots.removeAll()
        recentDiskWrites.removeAll()
        deliveredFrames = 0
        jpegEncodedFrames = 0
        failedEncodes = 0
        failedWrites = 0
        missingDirectories = 0
        diskBytes = 0
        compressedFrames.removeAll()
        compressedOrder.removeAll()
        compressedBytes = 0
        lastStorageError = ""
        hotImages.removeAllObjects()
        let version = generation
        let oldDirectory = legacyScopedDirectory
        lock.unlock()
        // Populate timeline coverage from this movie's previous sessions.
        // One directory scan, never one filesystem lookup per UI frame.
        diskReader.async { [weak self] in
            guard let self else { return }
            let files = [dir, oldDirectory].compactMap { $0 }.flatMap { directory in
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            }
            let slots = Set(files.compactMap { file -> Int? in
                let name = file.lastPathComponent
                guard name.hasPrefix("frame-"), name.hasSuffix(".jpg") else { return nil }
                return Int(name.dropFirst(6).dropLast(4))
            })
            self.lock.lock()
            if self.scopedDirectory == dir && self.generation == version {
                self.cachedSlots.formUnion(slots)
            }
            self.lock.unlock()
        }
        diskWriter.async {
            try? FileManager.default.createDirectory(at: dir,
                withIntermediateDirectories: true)
            // Regenerable thumbnails should never enter an iCloud backup.
            var backupRoot = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? backupRoot.setResourceValues(values)
        }
    }

    /// A rolling eight-second average of actual JPEG bytes successfully
    /// written to local storage, NOT incoming video bandwidth.
    func cacheStats() -> CacheStats {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-8)
        recentDiskWrites.removeAll { $0.date < cutoff }
        let bytes = recentDiskWrites.reduce(0) { $0 + $1.bytes }
        let coverage = cachedSlots.union(compressedFrames.keys)
        let result = CacheStats(slots: Array(coverage),
            writeMBPerSecond: Double(bytes) / 8_000_000.0,
            frameCount: coverage.count,
            deliveredFrames: deliveredFrames,
            jpegEncodedFrames: jpegEncodedFrames,
            failedEncodes: failedEncodes,
            failedWrites: failedWrites,
            missingDirectories: missingDirectories,
            diskBytes: diskBytes,
            diskFrames: cachedSlots.count,
            ramOnlyFrames: coverage.count - cachedSlots.count,
            storageError: lastStorageError)
        lock.unlock()
        return result
    }

    /// In-memory lookup is instantaneous for SDR, HDR and DV.
    func cachedImage(second: Int) -> UIImage? {
        if let image = hotImages.object(forKey: key(second)) {
            return image
        }
        lock.lock()
        let compressed = compressedFrames[bucket(second)]
        lock.unlock()
        return compressed.flatMap(UIImage.init(data:))
    }

    /// Cache-only lookups never wait for the media decoder or a pause.
    /// Search the exact 2s bucket first, then nearby frames (at most 6s).
    /// Cancel superseded scrubs before disk access to avoid I/O backlogs.
    func lookupCached(second: Int,
                      callback: @escaping (UIImage?, Int?, Bool) -> Void) {
        let slot = bucket(second)
        lock.lock()
        latestCacheLookup &+= 1
        let lookup = latestCacheLookup
        let version = generation
        let directory = scopedDirectory
        let legacy = legacyScopedDirectory
        lock.unlock()
        diskReader.async { [weak self] in
            guard let self else { return }
            var found: UIImage?
            var foundSlot: Int?
            let candidates = [slot, slot - 2, slot + 2,
                              slot - 4, slot + 4, slot - 6, slot + 6]
            for candidate in candidates where candidate >= 0 {
                self.lock.lock()
                let stillCurrent = self.generation == version
                    && self.latestCacheLookup == lookup
                self.lock.unlock()
                if !stillCurrent { return }
                if let image = self.cachedImage(second: candidate)
                    ?? self.readDisk(slot: candidate, directory: directory)
                    ?? self.readDisk(slot: candidate, directory: legacy) {
                    found = image
                    foundSlot = candidate
                    self.hotImages.setObject(image, forKey: self.key(candidate),
                        cost: max(1, Int(image.size.width * image.size.height * 4)))
                    break
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let valid = self.generation == version
                    && self.latestCacheLookup == lookup
                self.lock.unlock()
                if valid { callback(found, foundSlot, foundSlot == slot) }
            }
        }
    }

    /// Receive an already-decoded frame through the native video tap.
    /// The seek worker can be blocked by remote AVFoundation requests, so
    /// NEVER enqueue playback captures onto that same queue.
    /// Normal playback needs only a small retained UIImage; JPEG encoding
    /// and all filesystem operations run on the serial disk writer.
    func cachePlaybackFrame(_ image: UIImage, second: Int) {
        let slot = bucket(second)
        lock.lock()
        let primary = scopedDirectory
        let fallback = legacyScopedDirectory
        let epoch = cacheEpoch
        deliveredFrames += 1
        lock.unlock()

        // Make the decoded image usable immediately, even if disk is full.
        hotImages.setObject(image, forKey: key(slot),
            cost: max(1, Int(image.size.width * image.size.height * 4)))

        diskWriter.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.cacheEpoch == epoch &&
                self.scopedDirectory == primary
            self.lock.unlock()
            guard valid else { return }

            // One 720px frame every ~2sec. Keeping a 24MiB compressed RAM
            // ring permits real cached thumbnails even if disk IO fails.
            guard let bytes = image.jpegData(compressionQuality: 0.78) else {
                self.lock.lock()
                self.failedEncodes += 1
                self.lock.unlock()
                NSLog("[NuvioCache] JPEG encoder rejected slot %d", slot)
                return
            }
            self.lock.lock()
            self.jpegEncodedFrames += 1
            if self.compressedFrames[slot] == nil {
                self.compressedFrames[slot] = bytes
                self.compressedOrder.append(slot)
                self.compressedBytes += bytes.count
                while self.compressedBytes > self.compressedLimit,
                      !self.compressedOrder.isEmpty {
                    let oldest = self.compressedOrder.removeFirst()
                    if let old = self.compressedFrames.removeValue(forKey: oldest) {
                        self.compressedBytes -= old.count
                    }
                }
            }
            self.lock.unlock()

            let fm = FileManager.default
            let locations = [primary, fallback].compactMap { $0 }
            var storageError: NSError?
            var stored = false

            // Application Support is preferred for persistence. tvOS can
            // refuse that path on a particular build; retry in Library/Caches
            // which remains discoverable by our seeking and resume logic.
            for directory in locations {
                let file = directory.appendingPathComponent("frame-\(slot).jpg")
                if fm.fileExists(atPath: file.path) {
                    stored = true
                    break
                }
                do {
                    try fm.createDirectory(at: directory,
                                           withIntermediateDirectories: true)
                    do {
                        try bytes.write(to: file, options: .atomic)
                    } catch {
                        // Some tvOS file providers reject temp-file rename
                        // used by .atomic. Direct JPEG writes are tiny and
                        // still preferable to discarding good preview data.
                        try bytes.write(to: file, options: [])
                    }
                    stored = true
                    break
                } catch {
                    storageError = error as NSError
                    NSLog("[NuvioCache] JPEG write failed at %@: %@ (%d) %@",
                          directory.lastPathComponent,
                          storageError?.domain ?? "unknown",
                          storageError?.code ?? -1,
                          storageError?.localizedDescription ?? "unknown")
                }
            }
            self.lock.lock()
            if self.cacheEpoch == epoch {
                if stored {
                    let wasNew = self.cachedSlots.insert(slot).inserted
                    if wasNew {
                        self.diskBytes += Int64(bytes.count)
                        let now = Date()
                        self.recentDiskWrites.append((date: now, bytes: bytes.count))
                        self.recentDiskWrites.removeAll {
                            $0.date < now.addingTimeInterval(-8)
                        }
                    }
                    self.lastStorageError = ""
                } else {
                    self.failedWrites += 1
                    self.lastStorageError = storageError.map {
                        "\($0.domain):\($0.code) \($0.localizedDescription)"
                    } ?? "No writable preview cache directory"
                }
            }
            self.lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        latestCacheLookup &+= 1
        activeToken?.cancelled = true
        pending = nil
        pendingBackground = nil
        lock.unlock()
    }

    /// Wait until the serial system frame generator is no longer active
    /// before allowing the main playback engine to seek.
    func cancelAndDrain(_ completion: @escaping () -> Void) {
        cancel()
        worker.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    func clear() {
        cancel()
        lock.lock()
        cacheEpoch &+= 1
        sourceKey = nil
        scopedDirectory = nil
        legacyScopedDirectory = nil
        backgroundPrefetchUnavailable = false
        cachedSlots.removeAll()
        recentDiskWrites.removeAll()
        deliveredFrames = 0
        jpegEncodedFrames = 0
        failedEncodes = 0
        failedWrites = 0
        missingDirectories = 0
        diskBytes = 0
        compressedFrames.removeAll()
        compressedOrder.removeAll()
        compressedBytes = 0
        lastStorageError = ""
        hotImages.removeAllObjects()
        lock.unlock()
        // Intentionally DO NOT delete stored previews.
    }

    func request(url: URL, second: Int, allowSystemDecode: Bool = true,
                 callback: @escaping (UIImage?) -> Void) {
        let slot = bucket(second)
        if let cached = cachedImage(second: slot) {
            DispatchQueue.main.async { callback(cached) }
            return
        }
        lock.lock()
        let request = Request(url: url, second: slot,
                              prefetch: false, allowSystemDecode: allowSystemDecode,
                              callback: callback)
        pending = request
        // A foreground preview always supersedes any background decode.
        if activeWasBackground { activeToken?.cancelled = true }
        scheduleWorkerLocked()
        lock.unlock()
    }

    /// Opportunistically generate one thumbnail near playback. Uses the
    /// same serial decoder and is always lower priority than user seeking.
    func prefetch(url: URL, second: Int) {
        // No second decoder for MKV/HDR/DV; caller enables this only for SDR.
        guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return }
        let slot = bucket(second)
        if hotImages.object(forKey: key(slot)) != nil { return }
        lock.lock()
        if !backgroundPrefetchUnavailable, pending == nil, pendingBackground == nil {
            pendingBackground = Request(url: url, second: slot,
                                        prefetch: true, allowSystemDecode: true,
                                        callback: nil)
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
        diskWriter.async { [weak self] in
            let fm = FileManager.default
            guard !fm.fileExists(atPath: file.path) else { return }
            try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            do {
                try bytes.write(to: file, options: .atomic)
                guard let self else { return }
                self.lock.lock()
                if self.scopedDirectory == directory {
                    self.cachedSlots.insert(slot)
                    let now = Date()
                    self.recentDiskWrites.append((date: now, bytes: bytes.count))
                    let cutoff = now.addingTimeInterval(-8)
                    self.recentDiskWrites.removeAll { $0.date < cutoff }
                }
                self.lock.unlock()
            } catch {
                // Out-of-space or tvOS permission issues must never stop video.
                NSLog("[NuvioCache] Thumbnail could not be stored: %@",
                      String(describing: error))
            }
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
            let legacyDirectory = legacyScopedDirectory
            let token = NuvioThumbnailAbortToken()
            activeToken = token
            activeWasBackground = job.prefetch
            lock.unlock()

            let currentDiskImage = readDisk(slot: job.second, directory: directory)
            let cached = cachedImage(second: job.second)
                ?? currentDiskImage
                ?? readDisk(slot: job.second, directory: legacyDirectory)
            let decoded: UIImage?
            if let cached {
                decoded = cached
            } else if token.cancelled || !job.allowSystemDecode {
                // HDR/DV uncached targets use the existing mpv decoder,
                // never a competing AVFoundation 4K generator.
                decoded = nil
            } else {
                // Do NOT invoke FFmpeg. It previously decoded 4K streams
                // independently of the main renderer and repeatedly caused
                // app termination. System-backed decoding is limited to
                // formats supported natively by AVFoundation.
                decoded = appleFallback(url: job.url, second: job.second)
            }

            lock.lock()
            let valid = generation == version && !token.cancelled
            let foregroundWaiting = pending != nil
            if valid, job.prefetch, decoded == nil {
                // Avoid repeating costly generator probes on unsupported sources.
                backgroundPrefetchUnavailable = true
            }
            if activeToken === token { activeToken = nil }
            activeWasBackground = false
            lock.unlock()

            if valid, let image = decoded {
                remember(image, slot: job.second, directory: directory,
                         writeToDisk: currentDiskImage == nil)
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
        // AVAssetImageGenerator supports native containers, not arbitrary
        // signed URL streams, MKV, WebM or unknown formats. Trying all of
        // them could block this serial queue for seconds before falling back.
        // Unknown types go directly to the already-open mpv decoder.
        guard ["mp4", "mov", "m4v", "m3u8"].contains(suffix) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 288)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
        guard let frame = try? generator.copyCGImage(
            at: CMTime(seconds: Double(second), preferredTimescale: 600),
            actualTime: nil
        ) else { return nil }
        return UIImage(cgImage: frame)
    }
}
