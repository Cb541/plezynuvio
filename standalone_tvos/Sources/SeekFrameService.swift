import Foundation
import UIKit

/// mpvRx November 18-style on-demand seek previews.
/// One persistent, independent FFmpeg decoder; no speculative whole-movie
/// indexing and no JPEG disk writes. Main playback's media cache is untouched.
/// The existing native frame tap can still cheaply supply played slots and
/// history artwork without a second decode (including native-only DV P5).
final class SeekFrameService {
    /// Called on the main thread for a completed older keyframe while the
    /// current target is still loading, as in Android mpvRx.
    var onInterimFrame: ((UIImage, Int) -> Void)?

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
        let autoCapturedSlots: Int
        let seekCapturedSlots: Int
        let aheadCapturedSlots: Int
        let aheadAttempts: Int
        let aheadFailures: Int
        let aheadLastSeconds: Double
        let aheadDisabled: Bool
        let futureDiskFrames: Int
        let furthestAheadSeconds: Int
        let previewTiming: String
    }

    private struct Request {
        let url: URL
        let slot: Int
        let session: UInt64
        let version: UInt64
        let allowSystemDecode: Bool
        let callback: (UIImage?) -> Void
    }

    private let worker = DispatchQueue(label: "com.cb541.nuvio.seek-on-demand", qos: .userInitiated)
    private let encoder = DispatchQueue(label: "com.cb541.nuvio.seek-jpeg-memory", qos: .utility)
    private let lock = NSLock()
    // Count ceilings match the Android architecture; byte ceilings protect
    // Apple TV playback at the existing (unchanged) preview resolution.
    private var hot = NuvioPreviewLRU<UIImage>(maxCount: 100, maxBytes: Int.max)
    private var compressed = NuvioPreviewLRU<Data>(maxCount: 256, maxBytes: 24 * 1024 * 1024)
    private var encodingSlots = Set<Int>()
    private var source: URL?
    private var session: UInt64 = 0
    private var version: UInt64 = 0
    private var lookupVersion: UInt64 = 0
    private var desiredSlot: Int?
    private var pending: Request?
    private var token: NuvioThumbnailAbortToken?
    private var running = false
    private var suspended = false
    private var nativeDolbyVisionOnly = false
    // Accessed exclusively on worker, never on the UI or encoder queue.
    private var decoder: NuvioThumbnailDecoder?
    private var delivered = 0
    private var encoded = 0
    private var failed = 0
    private var autoSlots = Set<Int>()
    private var seekSlots = Set<Int>()
    private var timing = ""

    // Only touched on the main queue. Rust performs network and decode work
    // on its own threads, independently of the MPV playback cache.
    private var nativePreview: NuvioOnDemandPreview?
    // Guarded by `lock`, and invalidated on every new seek target/session.
    private var nativeWaiting: Request?

    private func bucket(_ second: Int) -> Int { max(0, second) }

    /// Some browser-originated video CDNs require the same HTTP context as
    /// their web player for random-access thumbnail reads. Only apply these
    /// headers to known ePorner-owned hosts; never send them to other sites.
    private static func extraPreviewHeaders(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased(),
              host == "eporner.com" || host.hasSuffix(".eporner.com")
        else { return [:] }
        return [
            "Referer": "https://www.eporner.com/",
            "User-Agent": "Mozilla/5.0 (AppleTV; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        ]
    }

    private func cost(_ image: UIImage) -> Int {
        if let cg = image.cgImage { return max(1, cg.bytesPerRow * cg.height) }
        return max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }

    /// New media owns a new session. Old queued decodes or JPEG callbacks
    /// must never populate a new video's cache, even if the URL is identical.
    func prepare(url: URL) { resetSession(to: url) }
    func clear() { resetSession(to: nil) }

    private func resetSession(to url: URL?) {
        lock.lock()
        session &+= 1
        let nativeEpoch = session
        version &+= 1
        lookupVersion &+= 1
        token?.cancelled = true
        pending = nil
        nativeWaiting = nil
        desiredSlot = nil
        source = url
        suspended = false
        nativeDolbyVisionOnly = false
        hot.removeAll()
        compressed.removeAll()
        encodingSlots.removeAll()
        delivered = 0
        encoded = 0
        failed = 0
        autoSlots.removeAll()
        seekSlots.removeAll()
        timing = ""
        // Queue before releasing the lock: a request for the next source
        // cannot enqueue a decode ahead of the old decoder's disposal.
        worker.async { [weak self] in
            self?.decoder?.reset()
            self?.decoder = nil
        }
        lock.unlock()
        configureNative(url: url, epoch: nativeEpoch)
    }

    /// Recreates the Rust session only when the movie changes. Initial index
    /// preparation is asynchronous and does not generate advance thumbnails.
    private func configureNative(url: URL?, epoch: UInt64) {
        let update = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.session == epoch && self.source == url
            self.lock.unlock()
            guard valid else { return }
            self.nativePreview?.close()
            self.nativePreview = nil
            guard let url else { return }
            self.nativePreview = NuvioOnDemandPreview(
                url: url, headers: Self.extraPreviewHeaders(for: url),
                thumbnailPixelWidth: url.isFileURL ? 512 : 0,
                imageReady: { [weak self] image, _ in
                    self?.nativeCompleted(image, epoch: epoch)
                },
                interimReady: { [weak self] image, at in
                    self?.nativeInterim(image, actualMilliseconds: at, epoch: epoch)
                },
                fallback: { [weak self] _ in
                    self?.nativeFallback(epoch: epoch)
                })
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    /// Android mpvRx displays completed older keyframes while seeking quickly.
    /// Cache that frame at its true keyframe position and show it as interim,
    /// but never mark the requested target complete or stop its spinner.
    private func nativeInterim(_ image: UIImage, actualMilliseconds: UInt64, epoch: UInt64) {
        let second = Int(actualMilliseconds / 1_000)
        lock.lock()
        let valid = session == epoch && source != nil &&
            !suspended && !nativeDolbyVisionOnly
        if valid {
            storeLocked(image, slot: second, automatic: false,
                        alreadyEncodedByRust: true)
        }
        lock.unlock()
        guard valid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillValid = self.session == epoch && self.source != nil &&
                !self.suspended && !self.nativeDolbyVisionOnly
            self.lock.unlock()
            if stillValid { self.onInterimFrame?(image, second) }
        }
    }

    /// Rust's keyframe result and the legacy extractor share the existing RAM
    /// store, so none of the UI's timestamp/last-good-frame logic is changed.
    private func nativeCompleted(_ image: UIImage, epoch: UInt64) {
        lock.lock()
        guard session == epoch, let job = nativeWaiting else { lock.unlock(); return }
        nativeWaiting = nil
        let valid = session == job.session && version == job.version &&
            source == job.url && !suspended && !nativeDolbyVisionOnly
        if valid {
            storeLocked(image, slot: job.slot, automatic: false, alreadyEncodedByRust: true)
            timing = "rust-indexed-keyframe"
        }
        lock.unlock()
        if valid {
            deliver(image, session: job.session, version: job.version,
                    callback: job.callback)
        }
    }

    /// Unsupported formats, servers without Range support, and native request
    /// timeouts fall back to the original independent FFmpeg seek worker.
    private func nativeFallback(epoch: UInt64) {
        lock.lock()
        guard session == epoch, let job = nativeWaiting else { lock.unlock(); return }
        nativeWaiting = nil
        let valid = session == job.session && version == job.version &&
            source == job.url && !suspended && !nativeDolbyVisionOnly
        if valid {
            pending = job
            scheduleLocked()
        }
        lock.unlock()
    }

    func cacheStats() -> CacheStats {
        lock.lock()
        defer { lock.unlock() }
        let slots = hot.keys.union(compressed.keys)
        return CacheStats(slots: Array(slots), writeMBPerSecond: 0,
            frameCount: slots.count, deliveredFrames: delivered,
            jpegEncodedFrames: encoded, failedEncodes: failed,
            failedWrites: 0, missingDirectories: 0, diskBytes: 0,
            diskFrames: 0, ramOnlyFrames: slots.count, storageError: "",
            autoCapturedSlots: autoSlots.intersection(slots).count,
            seekCapturedSlots: seekSlots.intersection(slots).count,
            aheadCapturedSlots: 0, aheadAttempts: 0, aheadFailures: 0,
            aheadLastSeconds: 0, aheadDisabled: true, futureDiskFrames: 0,
            furthestAheadSeconds: 0, previewTiming: timing)
    }

    func cachedImage(second: Int) -> UIImage? {
        let slot = bucket(second)
        lock.lock()
        if let image = hot.get(slot) {
            lock.unlock()
            return image
        }
        let data = compressed.get(slot)
        let epoch = session
        lock.unlock()
        guard let data, let image = UIImage(data: data) else { return nil }
        lock.lock()
        let valid = session == epoch && source != nil
        if valid { hot.put(image, key: slot, cost: cost(image)) }
        lock.unlock()
        return valid ? image : nil
    }

    func hasCachedFrame(second: Int) -> Bool {
        let slot = bucket(second)
        lock.lock()
        defer { lock.unlock() }
        return hot.contains(slot) || compressed.contains(slot)
    }

    func hasCachedFrameNear(second: Int) -> Bool {
        let slot = bucket(second)
        lock.lock()
        defer { lock.unlock() }
        return [slot, slot - 12, slot + 12].contains {
            $0 >= 0 && (hot.contains($0) || compressed.contains($0))
        }
    }

    /// Only RAM is searched. An adjacent image is never labeled as an exact
    /// position; the existing UI keeps its previous good still while waiting.
    func lookupCached(second: Int, callback: @escaping (UIImage?, Int?, Bool) -> Void) {
        let slot = bucket(second)
        lock.lock()
        lookupVersion &+= 1
        let lookup = lookupVersion
        let epoch = session
        lock.unlock()
        let image = cachedImage(second: slot)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.session == epoch && self.lookupVersion == lookup
            self.lock.unlock()
            if valid { callback(image, image == nil ? nil : slot, image != nil) }
        }
    }

    /// Normal playback captures are opportunistic, not a separate download.
    /// Keep a bounded encoder queue to avoid bursts of full decoded images.
    func cachePlaybackFrame(_ image: UIImage, second: Int,
                            automatic: Bool = true, ahead: Bool = false) {
        let slot = bucket(second)
        lock.lock()
        defer { lock.unlock() }
        guard source != nil, !ahead else { return }
        // As on Android, ordinary playback does not generate or populate
        // seek thumbnails ahead of user requests. Keep the existing capture
        // path only when native Dolby Vision Profile 5 requires it.
        if automatic && !nativeDolbyVisionOnly { return }
        storeLocked(image, slot: slot, automatic: automatic)
    }

    private func storeLocked(_ image: UIImage, slot: Int, automatic: Bool, alreadyEncodedByRust: Bool = false) {
        let existed = hot.contains(slot) || compressed.contains(slot)
        if automatic && existed { return }
        hot.put(image, key: slot, cost: cost(image))
        delivered += 1
        if automatic { autoSlots.insert(slot) } else { seekSlots.insert(slot) }
        // Rust retains up to 256 native JPEGs; encoding them a second time
        // on Swift's JPEG queue causes unnecessary CPU contention while scrubbing.
        guard !alreadyEncodedByRust else { return }
        guard !compressed.contains(slot), !encodingSlots.contains(slot),
              encodingSlots.count < 8 else { return }

        let epoch = session
        encodingSlots.insert(slot)
        encoder.async { [weak self] in
            guard let self else { return }
            let bytes = image.jpegData(compressionQuality: 0.78)
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.session == epoch, self.source != nil else { return }
            self.encodingSlots.remove(slot)
            if let bytes {
                self.compressed.put(bytes, key: slot, cost: bytes.count)
                self.encoded += 1
            } else {
                self.failed += 1
            }
        }
    }

    private func selectLocked(_ slot: Int?) {
        guard desiredSlot != slot else { return }
        desiredSlot = slot
        version &+= 1
        lookupVersion &+= 1
        token?.cancelled = true
        pending = nil
        nativeWaiting = nil
    }

    /// Latest-position-wins, including moving to an already cached position.
    /// Do not let stale HTTP seeks block the new request or replace its image.
    func cancelObsolete(second: Int) {
        lock.lock()
        selectLocked(bucket(second))
        lock.unlock()
        // Keep Rust's in-flight indexed reads alive as the seek target moves.
        // Version checks discard obsolete results; the next request changes
        // Rust's desired keyframe without clearing its fetched packets/cache.
        // Full dismiss/clear is reserved for exiting or committing a seek.
    }

    func request(url: URL, second: Int, allowSystemDecode: Bool = true,
                 callback: @escaping (UIImage?) -> Void) {
        let slot = bucket(second)
        lock.lock()
        guard source == url, !suspended else { lock.unlock(); return }
        selectLocked(slot)
        let epoch = session
        let requestVersion = version
        if let image = hot.get(slot) {
            lock.unlock()
            deliver(image, session: epoch, version: requestVersion, callback: callback)
            return
        }
        if let bytes = compressed.get(slot) {
            lock.unlock()
            let image = UIImage(data: bytes)
            deliver(image, session: epoch, version: requestVersion, callback: callback)
            return
        }
        guard !nativeDolbyVisionOnly else {
            lock.unlock()
            deliver(nil, session: epoch, version: requestVersion, callback: callback)
            return
        }

        let job = Request(url: url, slot: slot, session: epoch,
                          version: requestVersion, allowSystemDecode: allowSystemDecode,
                          callback: callback)
        // Native's network/index/decode pipeline is fully independent of MPV.
        // Retain the existing FFmpeg worker as a general fallback.
        if allowSystemDecode, Thread.isMainThread, let nativePreview {
            nativeWaiting = job
            lock.unlock()
            nativePreview.request(milliseconds: UInt64(slot) * 1_000)
        } else {
            pending = job
            scheduleLocked()
            lock.unlock()
        }
    }

    func setNativeDolbyVisionOnly(_ enabled: Bool) {
        lock.lock()
        nativeDolbyVisionOnly = enabled
        if enabled { selectLocked(nil) }
        lock.unlock()
        if enabled, Thread.isMainThread { nativePreview?.dismiss() }
    }

    /// Compatibility hooks: the old ahead scheduler is deliberately disabled.
    func updateAheadIndex(url: URL, playback: Double, duration: Double) {}
    func pauseAheadIndex() {}

    func cancel() {
        lock.lock()
        version &+= 1
        lookupVersion &+= 1
        desiredSlot = nil
        pending = nil
        nativeWaiting = nil
        token?.cancelled = true
        lock.unlock()
        if Thread.isMainThread { nativePreview?.dismiss() }
    }

    /// Avoid main-player/preview decoder contention when committing a seek.
    /// The session's RAM thumbnails survive; only the decoder is drained.
    func cancelAndDrain(_ completion: @escaping () -> Void) {
        lock.lock()
        suspended = true
        let epoch = session
        version &+= 1
        lookupVersion &+= 1
        desiredSlot = nil
        pending = nil
        nativeWaiting = nil
        token?.cancelled = true
        if Thread.isMainThread { nativePreview?.dismiss() }
        worker.async { [weak self] in
            guard let self else { return }
            self.decoder?.reset()
            DispatchQueue.main.async {
                self.lock.lock()
                if self.session == epoch {
                    self.suspended = false
                    self.scheduleLocked()
                }
                self.lock.unlock()
                completion()
            }
        }
        lock.unlock()
    }

    private func scheduleLocked() {
        guard !running, !suspended, pending != nil else { return }
        running = true
        worker.async { [weak self] in self?.processOne() }
    }

    private func processOne() {
        lock.lock()
        guard !suspended, let job = pending else {
            running = false
            lock.unlock()
            return
        }
        pending = nil
        let abort = NuvioThumbnailAbortToken()
        token = abort
        lock.unlock()

        let image: UIImage? = autoreleasepool {
            guard !abort.cancelled, job.allowSystemDecode else { return nil }
            if decoder == nil { decoder = NuvioThumbnailDecoder() }
            // Existing native persistent demuxer, keyframe-first extraction,
            // progressive HTTP ranges and HDR-correct SDR thumbnails.
            // No second AVFoundation player, no background video download.
            return decoder?.foregroundKeyframeThumbnail(for: job.url,
                second: Int64(job.slot), timeoutSeconds: 8, token: abort)
        }

        lock.lock()
        let valid = session == job.session && version == job.version
            && !abort.cancelled && source == job.url && !nativeDolbyVisionOnly
        if valid {
            timing = decoder?.lastTimingSummary ?? ""
            if let image { storeLocked(image, slot: job.slot, automatic: false) }
        }
        if token === abort { token = nil }
        running = false
        scheduleLocked()
        lock.unlock()
        if valid { deliver(image, session: job.session, version: job.version, callback: job.callback) }
    }

    private func deliver(_ image: UIImage?, session epoch: UInt64, version requestVersion: UInt64,
                         callback: @escaping (UIImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.session == epoch && self.version == requestVersion
            self.lock.unlock()
            if valid { callback(image) }
        }
    }
}
