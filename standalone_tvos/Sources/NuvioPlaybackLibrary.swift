import UIKit
import CryptoKit
import Security

/// Small, durable playback history. Video URLs live in the device-only Keychain,
/// not in the JSON file or logs; preview JPEGs live outside the seek cache.
struct NuvioHistoryItem: Codable, Hashable {
    var id: String
    var title: String
    var videoId: String?
    var contentId: String?
    var artworkURL: String?
    // Season artwork comes directly from Nuvio's configured TMDB integration.
    var seasonArtworkURL: String?
    var position: Double
    var duration: Double
    var lastOpened: Date

    var isInProgress: Bool {
        position >= 20 && duration > 0 && position / duration < 0.90
    }

    /// Stremio series episodes use <imdb>:<season>:<episode>.
    /// Avoid treating an ordinary movie with an IMDb ID as a television series.
    var episodeNumbers: (season: Int, episode: Int)? {
        NuvioRecentPosterCaption.episodeNumbers(videoId: videoId)
    }

    var seriesIMDbId: String? {
        guard episodeNumbers != nil else { return nil }
        return [contentId, videoId].compactMap { raw in
            guard let raw, let match = raw.range(
                of: #"tt[0-9]{5,12}"#, options: .regularExpression) else { return nil }
            return String(raw[match])
        }.first
    }
}

final class NuvioPlaybackLibrary {
    static let shared = NuvioPlaybackLibrary()
    static let changed = Notification.Name("NuvioPlaybackLibraryChanged")
    private let fm = FileManager.default
    private let appRoot: URL
    private let artRoot: URL
    private(set) var items: [NuvioHistoryItem] = []
    // Retry failed metadata lookups rather than permanently blacklisting cards.
    private var posterLookups: [String: Date] = [:]
    private var artworkDownloads = Set<String>()
    private var artworkRetryAt: [String: Date] = [:]
    private var artworkActiveURLs: [String: String] = [:]
    private var artworkAlternates: [String: [URL]] = [:]
    private var artworkFailedURL: [String: String] = [:]
    // Keep each artwork tier separate: a late-arriving series poster must not
    // overwrite an already available poster from the correct season.
    private var liveArtwork: [String: UIImage] = [:]
     private var artworkDiagnostics: [String: String] = [:]

    func artworkStatus(for entry: NuvioHistoryItem) -> String {
        artworkDiagnostics[entry.id] ??
            ((entry.artworkURL != nil || entry.contentId != nil)
                ? "Poster lookup pending" : "Looking up poster by title")
    }

    private func updateArtworkStatus(_ status: String, id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        guard artworkDiagnostics[id] != status else { return }
        artworkDiagnostics[id] = status
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private init() {
        appRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NuvioPlaybackLibrary", isDirectory: true)
        artRoot = appRoot.appendingPathComponent("Artwork", isDirectory: true)
        try? fm.createDirectory(at: artRoot, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: appRoot.appendingPathComponent("items.json")),
           let decoded = try? JSONDecoder().decode([NuvioHistoryItem].self, from: data) {
            items = decoded.sorted { $0.lastOpened > $1.lastOpened }
        }
    }

    func identifier(for media: NativeStreamLink) -> String {
        let identity = media.videoId ?? media.contentId ?? (
            media.title.lowercased() + "|" + (media.url.host ?? "") +
            media.url.path
        )
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func item(for media: NativeStreamLink) -> NuvioHistoryItem? {
        items.first { $0.id == identifier(for: media) }
    }

    /// Remove ONLY one Recent entry, not the underlying movie or episode.
    /// Clear its saved handoff token and cached artwork so it cannot return
    /// on the next launch. The next explicit playback can add it again.
    @discardableResult
    func removeRecentItem(id: String) -> Bool {
        precondition(Thread.isMainThread, "Recent history must be modified on the main thread")
        guard items.contains(where: { $0.id == id }) else { return false }
        items.removeAll { $0.id == id }

        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cb541.nuvionativeplayer.history",
            kSecAttrAccount as String: "NuvioHistory:" + id
        ]
        SecItemDelete(keychainQuery as CFDictionary)

        for variant in ["provided", "season", "better", "poster", "episode"] {
            liveArtwork.removeValue(forKey: variant + ":" + id)
            try? fm.removeItem(at: artRoot.appendingPathComponent(variant + "-" + id + ".jpg"))
        }
        try? fm.removeItem(at: artRoot.appendingPathComponent(id + ".jpg"))
        posterLookups.removeValue(forKey: id)
        artworkDiagnostics.removeValue(forKey: id)
        artworkDownloads = Set(artworkDownloads.filter { !$0.hasSuffix(":" + id) })
        artworkRetryAt = artworkRetryAt.filter { !$0.key.hasSuffix(":" + id) }
        artworkActiveURLs = artworkActiveURLs.filter { !$0.key.hasSuffix(":" + id) }
        artworkAlternates = artworkAlternates.filter { !$0.key.hasSuffix(":" + id) }
        artworkFailedURL = artworkFailedURL.filter { !$0.key.hasSuffix(":" + id) }
        persist()
        return true
    }

    func opened(_ media: NativeStreamLink) {
        let id = identifier(for: media)
        let existing = items.first { $0.id == id }
        // A legacy Nuvio handoff might have cached a landscape backdrop.
        // When Nuvio starts sending the real portrait poster, discard that
        // old provided image so its file-exists check doesn't block refresh.
        if let incomingArtwork = media.artworkURL?.absoluteString,
           incomingArtwork != existing?.artworkURL {
            let cached = artRoot.appendingPathComponent("provided-" + id + ".jpg")
            try? fm.removeItem(at: cached)
            liveArtwork.removeValue(forKey: "provided:" + id)
            artworkDiagnostics.removeValue(forKey: id)
        }
        // An incoming TMDB season URL supersedes older cached season art
        // (including any legacy TVmaze file from an earlier build).
        if let incoming = media.seasonArtworkURL?.absoluteString,
           incoming != existing?.seasonArtworkURL {
            try? fm.removeItem(at:
                artRoot.appendingPathComponent("season-" + id + ".jpg"))
            liveArtwork.removeValue(forKey: "season:" + id)
        }
        items.removeAll { $0.id == id }
        items.insert(NuvioHistoryItem(id: id, title: media.title,
            videoId: media.videoId, contentId: media.contentId,
            artworkURL: media.artworkURL?.absoluteString ?? existing?.artworkURL,
            seasonArtworkURL: media.seasonArtworkURL?.absoluteString ??
                existing?.seasonArtworkURL,
            position: existing?.position ?? 0, duration: existing?.duration ?? 0,
            lastOpened: Date()), at: 0)
        if items.count > 80 { items = Array(items.prefix(80)) }
        saveURL(media.url, for: id)
        persist()
        // New Nuvio handoffs may provide artwork; old custom builds often didn't.
        // Keep their backdrops as a fallback, and look up a proper portrait
        // poster by IMDb id when the incoming stream contains one.
        if let url = media.artworkURL {
            fetchArtwork(url, id: id, variant: "provided")
        }
        if let entry = items.first(where: { $0.id == id }) {
            fetchSeasonPoster(for: entry)
            fetchBetterPoster(for: entry)
            fetchMetadataPoster(for: entry)
            fetchEpisodeStillIfNeeded(for: entry)
        }
    }

    func update(_ media: NativeStreamLink, position: Double, duration: Double,
                finished: Bool = false, frame: UIImage? = nil) {
        guard position.isFinite, duration.isFinite, duration >= 0 else { return }
        let id = identifier(for: media)
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].position = finished ? 0 : max(0, position)
            items[index].duration = max(duration, items[index].duration)
            items[index].lastOpened = Date()
        } else {
            opened(media)
            update(media, position: position, duration: duration,
                   finished: finished, frame: frame)
            return
        }
        if let frame { saveArtwork(frame, id: id, onlyIfAbsent: true) }
        persist()
    }

    /// Repair artwork for previously saved titles, including entries made by
    /// Nuvio builds that sent just a title and signed stream URL.
    func prepareRecentArtwork() {
        for entry in items.prefix(35) {
            if let raw = entry.artworkURL, let url = URL(string: raw) {
                fetchArtwork(url, id: entry.id, variant: "provided")
            }
            fetchSeasonPoster(for: entry)
            fetchBetterPoster(for: entry)
            fetchMetadataPoster(for: entry)
            fetchEpisodeStillIfNeeded(for: entry)
        }
    }

    func artwork(for entry: NuvioHistoryItem) -> UIImage? {
        // Use Better Posters for movies and shows, but retain the selected
        // season's TMDB artwork for episodes whenever Nuvio provides it.
        // Decoded and disk-persisted artwork have identical precedence, so
        // existing history automatically upgrades as Better Posters loads.
        // Older/fallback art remains available if the service is offline.
        let variants = NuvioBetterPosters.orderedVariants(
            isEpisode: entry.episodeNumbers != nil,
            hasSeasonArtwork: entry.seasonArtworkURL != nil)
        for variant in variants {
            let key = variant + ":" + entry.id
            if let image = liveArtwork[key] { return image }
            let path = artRoot.appendingPathComponent(
                variant + "-" + entry.id + ".jpg").path
            if let image = UIImage(contentsOfFile: path) { return image }
        }
        return UIImage(contentsOfFile:
            artRoot.appendingPathComponent(entry.id + ".jpg").path)
    }

    func openLink(for entry: NuvioHistoryItem) -> NativeStreamLink? {
        guard let url = loadURL(for: entry.id) else { return nil }
        var components = URLComponents()
        components.scheme = "nuvio-player"
        components.host = "stream"
        var query = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "title", value: entry.title),
            URLQueryItem(name: "history", value: "1"),
            URLQueryItem(name: "resume", value: String(entry.position))
        ]
        if let id = entry.videoId { query.append(URLQueryItem(name: "videoId", value: id)) }
        if let id = entry.contentId { query.append(URLQueryItem(name: "contentId", value: id)) }
        if let art = entry.artworkURL { query.append(URLQueryItem(name: "artwork", value: art)) }
        if let art = entry.seasonArtworkURL {
            query.append(URLQueryItem(name: "seasonArtwork", value: art))
        }
        components.queryItems = query
        guard let link = components.url else { return nil }
        return NativeStreamLink(link: link)
    }

    private func persist() {
        try? fm.createDirectory(at: appRoot, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: appRoot.appendingPathComponent("items.json"),
                            options: .atomic)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func saveArtwork(_ image: UIImage, id: String, onlyIfAbsent: Bool) {
        let destination = artRoot.appendingPathComponent(id + ".jpg")
        if onlyIfAbsent && fm.fileExists(atPath: destination.path) { return }
        let size = CGSize(width: 320, height: 180)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        let resized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        if let data = resized?.jpegData(compressionQuality: 0.70) {
            try? data.write(to: destination, options: .atomic)
        }
    }

    /// Bounded retryable network image download. Failed image requests used
    /// to fail silently and the gallery would show only the title forever.
    private func fetchArtwork(_ url: URL, id: String, variant: String) {
        guard let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil,
              ["season", "better", "poster", "provided", "episode"].contains(variant) else {
            updateArtworkStatus("Poster URL invalid", id: id)
            return
        }
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.fetchArtwork(url, id: id, variant: variant)
            }
            return
        }
        // An asynchronous metadata result must not queue artwork again for
        // an entry the user explicitly removed while the request was running.
        guard items.contains(where: { $0.id == id }) else { return }
        let destination = artRoot.appendingPathComponent(variant + "-" + id + ".jpg")
        if fm.fileExists(atPath: destination.path),
           UIImage(contentsOfFile: destination.path) != nil { return }
        let lookupKey = variant + ":" + id
        if artworkDownloads.contains(lookupKey) {
            if artworkActiveURLs[lookupKey] != url.absoluteString {
                var alternates = artworkAlternates[lookupKey] ?? []
                if !alternates.contains(where: { $0.absoluteString == url.absoluteString }) {
                    alternates.append(url)
                    artworkAlternates[lookupKey] = alternates
                }
            }
            return
        }
        if let retry = artworkRetryAt[lookupKey], retry > Date(),
           artworkFailedURL[lookupKey] == url.absoluteString { return }
        artworkDownloads.insert(lookupKey)
        artworkActiveURLs[lookupKey] = url.absoluteString
        updateArtworkStatus("Loading image: " + (url.host ?? "CDN"), id: id)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 18
        request.setValue("image/jpeg,image/png,image/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // A poster request started before removal must never
                // recreate deleted artwork or change the Recent gallery.
                guard self.items.contains(where: { $0.id == id }) else { return }
                self.artworkDownloads.remove(lookupKey)
                self.artworkActiveURLs.removeValue(forKey: lookupKey)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200...299).contains(status),
                      let data, !data.isEmpty, data.count < 12_000_000,
                      let image = UIImage(data: data) else {
                    self.artworkRetryAt[lookupKey] = Date().addingTimeInterval(25)
                    self.artworkFailedURL[lookupKey] = url.absoluteString
                    let reason: String
                    if let error {
                        reason = "Network error " + String((error as NSError).code)
                    } else if !(200...299).contains(status) {
                        reason = "Image HTTP " + String(status)
                    } else if let data, !data.isEmpty {
                        reason = "Image format not decoded (" + String(data.count) + " bytes)"
                    } else {
                        reason = "Empty image response"
                    }
                    self.updateArtworkStatus(reason + " · " + (url.host ?? "unknown"), id: id)
                    // Never log signed media links or complete artwork URLs.
                    let errorCode = (error as NSError?)?.code ?? 0
                    NSLog("[NuvioArt] Image load failed host=%@ type=%@ status=%ld error=%ld",
                          url.host ?? "unknown", variant, status, errorCode)
                    if var alternates = self.artworkAlternates[lookupKey],
                       !alternates.isEmpty {
                        let alternate = alternates.removeFirst()
                        self.artworkAlternates[lookupKey] = alternates
                        self.fetchArtwork(alternate, id: id, variant: variant)
                    }
                    return
                }
                self.artworkRetryAt.removeValue(forKey: lookupKey)
                self.artworkFailedURL.removeValue(forKey: lookupKey)
                self.artworkAlternates.removeValue(forKey: lookupKey)
                self.liveArtwork[lookupKey] = image
                self.updateArtworkStatus("Poster decoded", id: id)
                self.savePoster(image, id: id, variant: variant)
                NSLog("[NuvioArt] Image cached type=%@ host=%@",
                      variant, url.host ?? "unknown")
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }.resume()
    }

    private func savePoster(_ image: UIImage, id: String, variant: String) {
        let destination = artRoot.appendingPathComponent(variant + "-" + id + ".jpg")
        guard image.size.width > 0, image.size.height > 0 else { return }
        // An interrupted/invalid JPEG used to block every later successful
        // download because fileExists alone was treated as valid artwork.
        if fm.fileExists(atPath: destination.path) {
            if UIImage(contentsOfFile: destination.path) != nil { return }
            try? fm.removeItem(at: destination)
        }
        // Keep high-resolution cards sharp on a 4K Apple TV. ScaleAspectFill
        // is applied at display time, so landscape fallback isn't distorted.
        let maxDimension: CGFloat = 920
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale),
                          height: max(1, image.size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: size)
        let data = renderer.jpegData(withCompressionQuality: 0.86) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        do {
            try data.write(to: destination, options: .atomic)
            if UIImage(contentsOfFile: destination.path) == nil {
                updateArtworkStatus("Poster decoded; disk reread failed", id: id)
            }
        } catch {
            updateArtworkStatus("Poster decoded; disk write failed", id: id)
        }
    }

    /// Apply the same Better Posters URL pattern used in Nuvio's other
    /// browsing screens. The IMDb ID (never a signed playback URL) is used
    /// as the lookup key. Old playback-history entries are eligible too.
    private func fetchBetterPoster(for entry: NuvioHistoryItem) {
        guard let url = NuvioBetterPosters.url(
            contentId: entry.contentId, videoId: entry.videoId) else { return }
        fetchArtwork(url, id: entry.id, variant: "better")
    }

    /// Nuvio resolves the selected season through its configured TMDB
    /// integration and sends only the public image URL. The external app
    /// never receives or stores the TMDB API key.
    private func fetchSeasonPoster(for entry: NuvioHistoryItem) {
        guard entry.episodeNumbers != nil,
              let raw = entry.seasonArtworkURL,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "image.tmdb.org" else { return }
        fetchArtwork(url, id: entry.id, variant: "season")
    }

    /// Fallback thumbnail from the episode metadata CDN. It never replaces
    /// an existing series poster, and a later season poster always wins.
    private func fetchEpisodeStillIfNeeded(for entry: NuvioHistoryItem) {
        guard let imdb = entry.seriesIMDbId,
              let numbers = entry.episodeNumbers,
              artwork(for: entry) == nil else { return }
        let endpoint = "https://episodes.metahub.space/" + imdb + "/" +
            String(numbers.season) + "/" + String(numbers.episode) + "/w780.jpg"
        if let url = URL(string: endpoint) {
            fetchArtwork(url, id: entry.id, variant: "episode")
        }
    }

    private func fetchMetadataPoster(for entry: NuvioHistoryItem) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.fetchMetadataPoster(for: entry)
            }
            return
        }
        let id = entry.id
        guard items.contains(where: { $0.id == id }) else { return }
        let posterPath = artRoot.appendingPathComponent("poster-" + id + ".jpg").path
        if fm.fileExists(atPath: posterPath),
           UIImage(contentsOfFile: posterPath) != nil { return }
        // Recover from intermittent network errors on the next gallery visit.
        if let last = posterLookups[id], Date().timeIntervalSince(last) < 35 { return }
        posterLookups[id] = Date()
        updateArtworkStatus("Finding artwork by metadata", id: id)

        let identifiers = [entry.contentId, entry.videoId].compactMap { $0 }
        let imdb = identifiers.compactMap({ value -> String? in
            guard let match = value.range(of: #"tt[0-9]{5,12}"#,
                                          options: .regularExpression) else { return nil }
            return String(value[match])
        }).first
        let looksLikeSeries = (entry.videoId ?? "").range(
            of: #":[0-9]+:[0-9]+$"#, options: .regularExpression) != nil
        if let imdb {
            // Stremio officially uses this deterministic poster endpoint.
            // It can succeed even when Cinemeta's JSON lookup does not.
            if let direct = URL(string:
                "https://images.metahub.space/poster/medium/" + imdb + "/img") {
                fetchArtwork(direct, id: id, variant: "poster")
            }
            let category = looksLikeSeries ? "series" : "movie"
            guard let endpoint = URL(string:
                "https://v3-cinemeta.strem.io/meta/" + category + "/" + imdb + ".json")
            else { return }
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, error == nil, (200...299).contains(status),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let meta = json["meta"] as? [String: Any],
                      let poster = meta["poster"] as? String,
                      let posterURL = URL(string: poster) else {
                    NSLog("[NuvioArt] Metadata missing type=%@ status=%ld",
                          category, status)
                    DispatchQueue.main.async { [weak self] in
                        self?.updateArtworkStatus("Metadata HTTP " + String(status), id: id)
                    }
                    return
                }
                DispatchQueue.main.async {
                    self?.fetchArtwork(posterURL, id: id, variant: "poster")
                }
            }.resume()
        } else {
            updateArtworkStatus("Searching title: " + entry.title, id: id)
            fetchTitleMatchedPoster(title: entry.title, id: id, category: "movie")
        }
    }

    private func fetchTitleMatchedPoster(title: String, id: String,
                                         category: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, clean.count <= 140,
              let encoded = clean.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
              let endpoint = URL(string:
                "https://v3-cinemeta.strem.io/catalog/" + category +
                "/top/search=" + encoded + ".json") else { return }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.items.contains(where: { $0.id == id }) else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200...299).contains(status),
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let metas = json["metas"] as? [[String: Any]] else {
                    let info = error.map { "Network error " + String(($0 as NSError).code) }
                        ?? "HTTP " + String(status)
                    self.updateArtworkStatus("Title search: " + info, id: id)
                    // If a movie search returns nothing, a show still may be
                    // found through the series catalog.
                    if category == "movie" {
                        self.fetchTitleMatchedPoster(title: clean, id: id, category: "series")
                    }
                    return
                }
                let match = metas.first {
                    guard let candidate = $0["name"] as? String else { return false }
                    return candidate.compare(clean,
                        options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                }
                if let poster = match?["poster"] as? String,
                   let url = URL(string: poster) {
                    self.fetchArtwork(url, id: id, variant: "poster")
                } else if category == "movie" {
                    self.fetchTitleMatchedPoster(title: clean, id: id, category: "series")
                } else {
                    self.updateArtworkStatus("No exact title match in Cinemeta", id: id)
                }
            }
        }.resume()
    }

    private func saveURL(_ url: URL, for id: String) {
        let account = "NuvioHistory:" + id
        let selector: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cb541.nuvionativeplayer.history",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(selector as CFDictionary)
        var attributes = selector
        attributes[kSecValueData as String] = Data(url.absoluteString.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func loadURL(for id: String) -> URL? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cb541.nuvionativeplayer.history",
            kSecAttrAccount as String: "NuvioHistory:" + id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: raw)
    }
}

/// One focused Recent gallery, instead of two duplicated rows. The
/// standalone player uses normal tvOS focusable buttons here (not RemoteSurface).
final class NuvioHistoryHomeView: UIView {
    var onSelect: ((NuvioHistoryItem) -> Void)?
    var onRequestRemove: ((NuvioHistoryItem) -> Void)?
    private let heading = UILabel()
    private let gallery = UIScrollView()
    private let tiles = UIStackView()
    private var cards: [String: NuvioHistoryTile] = [:]
    private var firstCard: UIButton?
    private var restoredFocusCard: UIButton?
    private var observer: NSObjectProtocol?
    private var artworkRetryTimer: Timer?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        (restoredFocusCard ?? firstCard).map { [$0] } ?? []
    }

    /// Prefer the next poster after a removal, or the previous one if the
    /// removed entry was last. Never land on a nonexistent focus target.
    func focusTargetAfterRemoving(_ id: String) -> String? {
        NuvioRecentFocus.nextID(
            in: Array(NuvioPlaybackLibrary.shared.items.prefix(35)).map(\.id),
            removing: id)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        heading.text = "Recently Played"
        heading.font = .systemFont(ofSize: 45, weight: .bold)
        heading.textColor = .white
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)

        gallery.translatesAutoresizingMaskIntoConstraints = false
        gallery.backgroundColor = .clear
        gallery.showsHorizontalScrollIndicator = false
        gallery.showsVerticalScrollIndicator = false
        gallery.clipsToBounds = false
        gallery.contentInsetAdjustmentBehavior = .never
        addSubview(gallery)

        tiles.translatesAutoresizingMaskIntoConstraints = false
        tiles.axis = .horizontal
        tiles.alignment = .top
        tiles.spacing = 36
        gallery.addSubview(tiles)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            // Preserve the existing poster row position while moving the heading up.
            gallery.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 88),
            gallery.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 74),
            gallery.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -40),
            // Keep the poster wall at its existing location and size. Movies
            // have poster-only tiles; episodes have a small S# Ep# caption.
            gallery.heightAnchor.constraint(equalToConstant: 700),
            tiles.topAnchor.constraint(equalTo: gallery.contentLayoutGuide.topAnchor, constant: 10),
            tiles.leadingAnchor.constraint(equalTo: gallery.contentLayoutGuide.leadingAnchor, constant: 4),
            tiles.trailingAnchor.constraint(equalTo: gallery.contentLayoutGuide.trailingAnchor, constant: -26),
            tiles.bottomAnchor.constraint(equalTo: gallery.contentLayoutGuide.bottomAnchor, constant: -14),
            tiles.heightAnchor.constraint(equalTo: gallery.frameLayoutGuide.heightAnchor, constant: -24)
        ])
        observer = NotificationCenter.default.addObserver(
            forName: NuvioPlaybackLibrary.changed, object: nil, queue: .main
        ) { [weak self] _ in
            // Downloaded artwork should update in place. Rebuilding buttons
            // destroys tvOS's focus target and makes the gallery unclickable.
            guard let self, !self.isHidden else { return }
            self.refreshArtwork()
        }
        reload()
        // Retry failed requests while Recent remains open. Success is disk
        // cached, so this does not repeatedly download finished posters.
        artworkRetryTimer = Timer.scheduledTimer(withTimeInterval: 12,
            repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            NuvioPlaybackLibrary.shared.prepareRecentArtwork()
            self.refreshArtwork()
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    deinit {
        artworkRetryTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload(preferredFocusID: String? = nil) {
        NuvioPlaybackLibrary.shared.prepareRecentArtwork()
        tiles.arrangedSubviews.forEach {
            tiles.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.removeAll()
        firstCard = nil
        restoredFocusCard = nil
        let all = Array(NuvioPlaybackLibrary.shared.items.prefix(35))
        if all.isEmpty {
            let empty = UILabel()
            empty.text = "Play a movie or episode from Nuvio to see it here."
            empty.textColor = UIColor.white.withAlphaComponent(0.60)
            empty.font = .systemFont(ofSize: 26, weight: .medium)
            tiles.addArrangedSubview(empty)
        } else {
            for item in all {
                let card = NuvioHistoryTile(item: item,
                    artwork: NuvioPlaybackLibrary.shared.artwork(for: item),
                    status: NuvioPlaybackLibrary.shared.artworkStatus(for: item))
                card.onClick = { [weak self] in self?.onSelect?(item) }
                card.onHold = { [weak self] in self?.onRequestRemove?(item) }
                tiles.addArrangedSubview(card)
                cards[item.id] = card
                if firstCard == nil { firstCard = card }
            }
            if let preferredFocusID {
                restoredFocusCard = cards[preferredFocusID]
            }
        }
    }

    private func refreshArtwork() {
        for item in NuvioPlaybackLibrary.shared.items {
            cards[item.id]?.updateArtwork(
                NuvioPlaybackLibrary.shared.artwork(for: item),
                status: NuvioPlaybackLibrary.shared.artworkStatus(for: item)
            )
        }
    }
}

private final class NuvioHistoryTile: UIButton {
    var onClick: (() -> Void)?
    var onHold: (() -> Void)?
    // Hold Select/center for a short while. Short Select stays unchanged.
    // Using UIPress events on the focused UIButton avoids a competing pan
    // recognizer that could steal normal poster selection/navigation.
    private var holdTimer: Timer?
    private var holdFired = false
    private let holdSeconds = 0.75
    private let art = UIImageView()
    private let placeholder = UILabel()
    private let posterStatus = UILabel()

    override var canBecomeFocused: Bool { true }

    init(item: NuvioHistoryItem, artwork: UIImage?, status: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = true
        widthAnchor.constraint(equalToConstant: 411).isActive = true
        // Movie tiles end at the poster. Episodes get only one compact
        // season/episode caption beneath the image, never the series title.
        let episodeCaption = NuvioRecentPosterCaption.caption(videoId: item.videoId)
        heightAnchor.constraint(equalToConstant: episodeCaption == nil ? 601 : 644).isActive = true
        accessibilityLabel = "Play " + item.title
        accessibilityTraits.insert(.button)

        let poster = UIView()
        poster.translatesAutoresizingMaskIntoConstraints = false
        poster.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1)
        poster.layer.cornerRadius = 12.1
        poster.clipsToBounds = true
        poster.isUserInteractionEnabled = false
        addSubview(poster)

        art.translatesAutoresizingMaskIntoConstraints = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.isUserInteractionEnabled = false
        poster.addSubview(art)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = item.title
        placeholder.textAlignment = .center
        placeholder.font = .systemFont(ofSize: 29, weight: .bold)
        placeholder.numberOfLines = 4
        placeholder.textColor = .white.withAlphaComponent(0.83)
        placeholder.isUserInteractionEnabled = false
        poster.addSubview(placeholder)

        // Temporary small diagnostics, visible only on blank poster cards.
        // No signed URLs, stream secrets, or file paths are displayed.
        posterStatus.translatesAutoresizingMaskIntoConstraints = false
        posterStatus.font = .systemFont(ofSize: 14, weight: .medium)
        posterStatus.textColor = UIColor.white.withAlphaComponent(0.66)
        posterStatus.numberOfLines = 2
        posterStatus.textAlignment = .center
        posterStatus.isUserInteractionEnabled = false
        poster.addSubview(posterStatus)

        NSLayoutConstraint.activate([
            poster.leadingAnchor.constraint(equalTo: leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: trailingAnchor),
            poster.topAnchor.constraint(equalTo: topAnchor),
            // Updated portrait card: 411 × 601pt, 5% wider than the previous 391pt.
            poster.heightAnchor.constraint(equalToConstant: 601),
            art.leadingAnchor.constraint(equalTo: poster.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: poster.trailingAnchor),
            art.topAnchor.constraint(equalTo: poster.topAnchor),
            art.bottomAnchor.constraint(equalTo: poster.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: poster.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: poster.trailingAnchor, constant: -16),
            placeholder.centerYAnchor.constraint(equalTo: poster.centerYAnchor),
            posterStatus.leadingAnchor.constraint(equalTo: poster.leadingAnchor, constant: 12),
            posterStatus.trailingAnchor.constraint(equalTo: poster.trailingAnchor, constant: -12),
            posterStatus.bottomAnchor.constraint(equalTo: poster.bottomAnchor, constant: -18)
        ])
        if let episodeCaption {
            let caption = UILabel()
            caption.text = episodeCaption
            caption.font = .systemFont(ofSize: 22, weight: .semibold)
            caption.textColor = .white
            caption.numberOfLines = 1
            caption.translatesAutoresizingMaskIntoConstraints = false
            caption.isUserInteractionEnabled = false
            addSubview(caption)
            NSLayoutConstraint.activate([
                caption.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 12),
                caption.leadingAnchor.constraint(equalTo: leadingAnchor),
                caption.trailingAnchor.constraint(equalTo: trailingAnchor),
                caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
            ])
        }
        if item.isInProgress, item.duration > 0 {
            let progress = UIProgressView(progressViewStyle: .default)
            progress.translatesAutoresizingMaskIntoConstraints = false
            progress.progressTintColor = .white
            progress.trackTintColor = UIColor.white.withAlphaComponent(0.30)
            progress.progress = Float(min(1, max(0, item.position / item.duration)))
            poster.addSubview(progress)
            NSLayoutConstraint.activate([
                progress.leadingAnchor.constraint(equalTo: poster.leadingAnchor, constant: 8),
                progress.trailingAnchor.constraint(equalTo: poster.trailingAnchor, constant: -8),
                progress.bottomAnchor.constraint(equalTo: poster.bottomAnchor, constant: -8),
                progress.heightAnchor.constraint(equalToConstant: 4)
            ])
        }
        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        updateArtwork(artwork, status: status)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func updateArtwork(_ image: UIImage?, status: String) {
        art.image = image
        placeholder.isHidden = image != nil
        posterStatus.isHidden = image != nil
        posterStatus.text = image == nil ? status : nil
    }

    @objc private func tapped() {
        // After a held Select, UIKit may still queue a primary action on
        // release. Never open the video while confirming deletion.
        guard !holdFired else { return }
        onClick?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            holdTimer?.invalidate()
            holdFired = false
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdSeconds,
                                             repeats: false) { [weak self] _ in
                guard let self, self.isFocused, self.window != nil else { return }
                self.holdTimer = nil
                self.holdFired = true
                self.onHold?()
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) {
            holdTimer?.invalidate()
            holdTimer = nil
            if holdFired {
                // Cancel rather than end UIButton's pressed state: this
                // avoids firing primaryActionTriggered after a long hold.
                super.pressesCancelled(presses, with: event)
                return
            }
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        holdTimer?.invalidate()
        holdTimer = nil
        super.pressesCancelled(presses, with: event)
    }

    deinit { holdTimer?.invalidate() }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if !isFocused {
            holdTimer?.invalidate()
            holdTimer = nil
        }
        coordinator.addCoordinatedAnimations({
            self.transform = self.isFocused
                ? CGAffineTransform(scaleX: 1.055, y: 1.055) : .identity
            // Keep the small focus scale, but no light halo or poster glow.
            self.layer.shadowOpacity = 0
            self.layer.shadowRadius = 0
            self.layer.zPosition = self.isFocused ? 5 : 0
        })
    }
}
