import AVFoundation
import UIKit

/// Truly standalone UIKit/tvOS application. No Flutter engine, Plex, or login.
@main
final class NuvioAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var controller: NativePlayerViewController?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("NuvioPlayer: audio-session setup error: %@", String(describing: error))
        }
        let ui = NativePlayerViewController()
        controller = ui
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ui
        window.makeKeyAndVisible()
        self.window = window
        if let url = launchOptions?[.url] as? URL {
            _ = handle(url)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        handle(url)
    }

    private func handle(_ url: URL) -> Bool {
        guard let media = NativeStreamLink(link: url) else { return false }
        controller?.open(media)
        return true
    }
}

/// Nuvio handoff: nuvio-player://stream?url=<encoded>&title=<encoded>&sub=<encoded>.
/// Rejects local-file and arbitrary scheme URLs. Does not print signed URLs.
struct NativeStreamLink {
    let url: URL
    let title: String
    let subtitle: URL?

    init?(link: URL) {
        guard link.scheme?.lowercased() == "nuvio-player",
              ["stream", "x-callback-url"].contains(link.host?.lowercased() ?? ""),
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let video = URL(string: value),
              ["https", "http"].contains(video.scheme?.lowercased() ?? ""),
              video.host != nil else { return nil }
        url = video
        title = components.queryItems?.first(where: { ["title", "name"].contains($0.name) })?.value ?? "Now Playing"
        if let value = components.queryItems?.first(where: { $0.name == "sub" })?.value,
           let subtitleURL = URL(string: value),
           ["https", "http"].contains(subtitleURL.scheme?.lowercased() ?? ""),
           subtitleURL.host != nil {
            subtitle = subtitleURL
        } else {
            subtitle = nil
        }
    }
}
