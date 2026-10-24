import AVFoundation
import UIKit

/// Application-level configuration only. A real UIWindowScene owns the video
/// window, so scene-based tvOS URL callbacks work for cold and warm starts.
@main
final class NuvioAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Clear orphaned range/video previews from previous sessions or a
        // forced termination. This never touches the durable history/artwork
        // in NuvioPlaybackLibrary.
        let fm = FileManager.default
        for base in [FileManager.SearchPathDirectory.cachesDirectory,
                     .applicationSupportDirectory] {
            guard let root = fm.urls(for: base, in: .userDomainMask).first else { continue }
            let seek = root.appendingPathComponent("NuvioSeekFrames", isDirectory: true)
            try? fm.removeItem(at: seek)
            if base == .cachesDirectory {
                try? fm.removeItem(at: root.appendingPathComponent("NuvioPreviewRanges",
                                                                 isDirectory: true))
            }
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("[NuvioNative] Audio session setup failed: %@", String(describing: error))
        }
        return true
    }
}

/// On tvOS 17+, deep links delivered to a scene arrive here rather than at
/// UIApplicationDelegate.application(_:open:options:).
final class NuvioSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var controller: NativePlayerViewController?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let player = NativePlayerViewController()
        controller = player
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = player
        self.window = window
        window.makeKeyAndVisible()
        NSLog("[NuvioNative] Scene connected")

        if let url = connectionOptions.urlContexts.first?.url {
            receive(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            receive(context.url)
            break
        }
    }

    private func receive(_ url: URL) {
        // NEVER log the URL: debrid links can contain bearer-like query tokens.
        NSLog("[NuvioNative] Received handoff scheme=%@ host=%@",
              url.scheme ?? "(none)", url.host ?? "(none)")
        guard let media = NativeStreamLink(link: url) else {
            controller?.showHandoffError("Unsupported or invalid Nuvio stream link")
            return
        }
        controller?.open(media)
    }
}

/// Nuvio handoff: nuvio-player://stream?url=<encoded>&title=<encoded>&sub=<encoded>.
/// Signed query items remain inside the 'url' value; nothing is uploaded/logged.
struct NativeStreamLink {
    let url: URL
    let title: String
    let subtitle: URL?
    let contentId: String?
    let videoId: String?
    let artworkURL: URL?
    let seasonArtworkURL: URL?
    let resumeSeconds: Double
    let isHistoryLaunch: Bool

    init?(link: URL) {
        guard link.scheme?.lowercased() == "nuvio-player",
              ["stream", "x-callback-url"].contains(link.host?.lowercased() ?? ""),
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let video = URL(string: value),
              ["https", "http"].contains(video.scheme?.lowercased() ?? ""),
              video.host != nil else { return nil }
        url = video
        let query = components.queryItems ?? []
        title = query.first(where: { ["title", "name"].contains($0.name) })?.value ?? "Now Playing"
        contentId = query.first(where: { $0.name == "contentId" })?.value
        videoId = query.first(where: { $0.name == "videoId" })?.value
        if let rawArt = query.first(where: { $0.name == "artwork" })?.value,
           let art = URL(string: rawArt),
           ["https", "http"].contains(art.scheme?.lowercased() ?? "") {
            artworkURL = art
        } else {
            artworkURL = nil
        }
        if let rawSeason = query.first(where: { $0.name == "seasonArtwork" })?.value,
           let seasonURL = URL(string: rawSeason),
           seasonURL.scheme?.lowercased() == "https",
           seasonURL.host?.lowercased() == "image.tmdb.org" {
            seasonArtworkURL = seasonURL
        } else {
            seasonArtworkURL = nil
        }
        resumeSeconds = max(0, Double(query.first(where: { $0.name == "resume" })?.value ?? "") ?? 0)
        isHistoryLaunch = query.contains { $0.name == "history" && $0.value == "1" }
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
