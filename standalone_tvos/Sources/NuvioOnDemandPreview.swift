import Foundation
import UIKit

/// Owns one Rust thumbnail session. Its public functions are called on the main
/// queue; network/index/decode work is performed by the native engine's workers.
/// UI geometry, overlays, and last-good-image behavior remain in the controller.
final class NuvioOnDemandPreview {
    private var handle: OpaquePointer?
    private var polling: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var target: UInt64?
    private var permanentlyUnavailable = false

    private let imageReady: (UIImage, UInt64) -> Void
    private let interimReady: (UIImage, UInt64) -> Void
    private let fallback: (UInt64) -> Void

    init?(url: URL, headers: [String: String] = [:], thumbnailPixelWidth: UInt32 = 640,
          imageReady: @escaping (UIImage, UInt64) -> Void,
          interimReady: @escaping (UIImage, UInt64) -> Void,
          fallback: @escaping (UInt64) -> Void) {
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8) else { return nil }
        self.imageReady = imageReady
        self.interimReady = interimReady
        self.fallback = fallback
        let source = url.isFileURL ? url.path : url.absoluteString
        handle = source.withCString { urlString in
            json.withCString { headerString in
                nvthumb_open(urlString, headerString, thumbnailPixelWidth)
            }
        }
        guard let handle else { return nil }
        nvthumb_prepare(handle) // Fetches the index asynchronously, not preview images.
    }

    func request(milliseconds: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let handle else { fallback(milliseconds); return }
        target = milliseconds
        generation &+= 1
        let requestID = generation
        polling?.cancel()
        if permanentlyUnavailable { fallback(milliseconds); return }
        // The seek controller already coalesces touchpad input to ~80 ms.
        // A SECOND 80 ms debounce here stalls every uncached picture, and
        // repeated scrubs can cancel the native request before it is sent.
        // Rust's Session::want itself is latest-target-wins and nonblocking.
        nvthumb_want(handle, milliseconds)
        pollForImage(requestID, deadline: ProcessInfo.processInfo.systemUptime + 6)
    }

    private func pollForImage(_ id: UInt64, deadline: TimeInterval) {
        guard generation == id, let handle, let target else { return }
        if let event = nvthumb_take(handle) {
            defer { nvthumb_event_free(event) }
            let actual = nvthumb_event_time(event)
            if actual < 0 { // Permanent unsupported codec/container/index.
                permanentlyUnavailable = true
                fallback(target)
                return
            }
            // The native index reports the exact keyframe timestamp; discard
            // late results from previously requested slots.
            var length = 0
            if let data = nvthumb_event_data(event, &length), length > 0,
               let image = UIImage(data: Data(bytes: data, count: length)) {
                if actual == nvthumb_keyframe(handle, target) {
                    imageReady(image, UInt64(actual))
                    return
                }
                // Android mpvRx publishes a completed older request as a
                // last-good frame while the newest keyframe is still loading.
                // Present it without incorrectly marking the newest target ready.
                interimReady(image, UInt64(actual))
            }
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            fallback(target)
            return
        }
        let next = DispatchWorkItem { [weak self] in
            self?.pollForImage(id, deadline: deadline)
        }
        polling = next
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16), execute: next)
    }

    /// Stops pending display work but retains Rust's cached JPEGs and index.
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        target = nil
        polling?.cancel()
        if let handle { nvthumb_clear(handle) }
    }

    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        dismiss()
        if let handle { nvthumb_close(handle) }
        handle = nil
    }

    deinit {
        polling?.cancel()
        if let handle { nvthumb_close(handle) }
    }
}
