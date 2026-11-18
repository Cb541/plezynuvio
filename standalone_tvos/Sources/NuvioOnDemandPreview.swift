import Foundation
import UIKit

/// Owns one Rust thumbnail session. Its public functions are called on the main
/// queue; network/index/decode work is performed by the native engine's workers.
/// UI geometry, overlays, and last-good-image behavior remain in the controller.
final class NuvioOnDemandPreview {
    private var handle: OpaquePointer?
    private var pending: DispatchWorkItem?
    private var polling: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var target: UInt64?
    private var permanentlyUnavailable = false
    private var lastSend: TimeInterval = -1

    private let imageReady: (UIImage, UInt64) -> Void
    private let fallback: (UInt64) -> Void

    init?(url: URL, headers: [String: String] = [:], thumbnailPixelWidth: UInt32 = 640,
          imageReady: @escaping (UIImage, UInt64) -> Void,
          fallback: @escaping (UInt64) -> Void) {
        guard url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: headers),
              let json = String(data: data, encoding: .utf8) else { return nil }
        self.imageReady = imageReady
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
        pending?.cancel()
        polling?.cancel()
        if permanentlyUnavailable { fallback(milliseconds); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let h = self.handle,
                  self.generation == requestID else { return }
            self.lastSend = ProcessInfo.processInfo.systemUptime
            nvthumb_want(h, milliseconds)
            self.pollForImage(requestID, deadline: ProcessInfo.processInfo.systemUptime + 6)
        }
        pending = work
        let elapsed = ProcessInfo.processInfo.systemUptime - lastSend
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.080 - elapsed), execute: work)
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
            if actual == nvthumb_keyframe(handle, target) {
                var length = 0
                if let data = nvthumb_event_data(event, &length), length > 0,
                   let image = UIImage(data: Data(bytes: data, count: length)) {
                    imageReady(image, UInt64(actual))
                    return
                }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20), execute: next)
    }

    /// Stops pending display work but retains Rust's cached JPEGs and index.
    func dismiss() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation &+= 1
        target = nil
        pending?.cancel()
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
        pending?.cancel()
        polling?.cancel()
        if let handle { nvthumb_close(handle) }
    }
}
