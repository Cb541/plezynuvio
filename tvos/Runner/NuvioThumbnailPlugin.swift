import Foundation
import Flutter
import Libmpv
import ImageIO
import UIKit

/// On-demand still frame extraction for the Nuvio external-player screen.
///
/// This is a completely separate libmpv context from the movie player. The
/// 'image' video output writes one decoded frame to a throwaway directory;
/// no playback seek, full media download, or persistently stored movie bytes.
/// Work is serialized and bounded, and neither URLs nor auth tokens are logged.
final class NuvioThumbnailPlugin: NSObject, FlutterPlugin {
  private static let queue = DispatchQueue(label: "com.plezy.nuvio.thumbnail", qos: .utility)
  private static let maxWait: TimeInterval = 7.0
  private static let maxImageBytes = 12 * 1024 * 1024

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.plezy/nuvio_thumbnails",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(NuvioThumbnailPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "frame" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
      let address = args["url"] as? String,
      address.count <= 16_384,
      let url = URL(string: address),
      let scheme = url.scheme?.lowercased(),
      (scheme == "http" || scheme == "https"),
      url.host != nil,
      let millis = (args["timeMs"] as? NSNumber)?.int64Value,
      millis >= 0,
      millis <= 24 * 60 * 60 * 1000
    else {
      result(nil)
      return
    }

    // Keep mpv creation, network seeks, decoder use and teardown off the UI
    // thread. One thumbnail decode at a time caps resource use on Apple TV.
    Self.queue.async {
      let image = Self.extractFrame(url: url, at: Double(millis) / 1000.0)
      DispatchQueue.main.async {
        result(image.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }

  private static func extractFrame(url: URL, at seconds: Double) -> Data? {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("nuvio-preview-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    defer { try? FileManager.default.removeItem(at: folder) }

    guard let context = mpv_create() else { return nil }
    defer { mpv_terminate_destroy(context) }

    let options: [(String, String)] = [
      ("config", "no"),
      ("terminal", "no"),
      ("msg-level", "all=error"),
      ("audio", "no"),
      ("aid", "no"),
      ("sid", "no"),
      ("hwdec", "no"),
      ("vo", "image"),
      ("vo-image-format", "jpg"),
      ("vo-image-jpeg-quality", "68"),
      ("vo-image-outdir", folder.path),
      ("frames", "1"),
      ("start", String(format: "%.3f", seconds)),
      ("hr-seek", "no"),
      ("keep-open", "no"),
      ("cache", "no"),
      ("demuxer-readahead-secs", "0.2"),
      ("force-window", "no")
    ]
    for (key, value) in options {
      // A missing image VO or option makes this backend unavailable. Do not
      // silently use the primary player's display output as a fallback.
      if mpv_set_option_string(context, key, value) < 0 { return nil }
    }
    guard mpv_initialize(context) >= 0 else { return nil }

    let command = ["loadfile", url.absoluteString, "replace"]
    let owned = command.compactMap { strdup($0) }
    guard owned.count == command.count else {
      for item in owned { free(item) }
      return nil
    }
    defer { for item in owned { free(item) } }
    var argv: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
    argv.append(nil)
    guard argv.withUnsafeBufferPointer({ mpv_command(context, $0.baseAddress) }) >= 0 else {
      return nil
    }

    let deadline = Date().addingTimeInterval(maxWait)
    while Date() < deadline {
      let event = mpv_wait_event(context, 0.15)
      if let file = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil
      ).first(where: { $0.pathExtension.lowercased() == "jpg" }),
         let image = reducedJPEG(at: file) {
        return image
      }
      if let event, event.pointee.event_id == MPV_EVENT_END_FILE {
        break
      }
    }
    return nil
  }

  /// Downscale to a small SDR JPEG and never pass full 4K frame images through
  /// the Flutter channel. ImageIO only creates the small thumbnail bitmap.
  private static func reducedJPEG(at file: URL) -> Data? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      let length = attributes[.size] as? NSNumber,
      length.intValue > 0 && length.intValue <= maxImageBytes
    else { return nil }
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 400
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.66)
  }
}
