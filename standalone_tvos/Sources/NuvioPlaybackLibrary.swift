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
    var position: Double
    var duration: Double
    var lastOpened: Date

    var isInProgress: Bool {
        position >= 20 && duration > 0 && position / duration < 0.90
    }
}

final class NuvioPlaybackLibrary {
    static let shared = NuvioPlaybackLibrary()
    static let changed = Notification.Name("NuvioPlaybackLibraryChanged")
    private let fm = FileManager.default
    private let appRoot: URL
    private let artRoot: URL
    private(set) var items: [NuvioHistoryItem] = []
    private var posterLookups = Set<String>()

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

    func opened(_ media: NativeStreamLink) {
        let id = identifier(for: media)
        let existing = items.first { $0.id == id }
        items.removeAll { $0.id == id }
        items.insert(NuvioHistoryItem(id: id, title: media.title,
            videoId: media.videoId, contentId: media.contentId,
            artworkURL: media.artworkURL?.absoluteString ?? existing?.artworkURL,
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
        fetchMetadataPoster(for: media, id: id)
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

    func artwork(for entry: NuvioHistoryItem) -> UIImage? {
        // A portrait poster should win over a landscape backdrop or an
        // opportunistic seek frame. Preserve the legacy JPEG as a last resort.
        for filename in ["poster-" + entry.id + ".jpg",
                         "provided-" + entry.id + ".jpg",
                         entry.id + ".jpg"] {
            if let image = UIImage(contentsOfFile:
                artRoot.appendingPathComponent(filename).path) {
                return image
            }
        }
        return nil
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

    /// Fetch Nuvio's poster/backdrop, using separate files so a landscape
    /// image cannot permanently block a better portrait poster.
    private func fetchArtwork(_ url: URL, id: String, variant: String) {
        guard url.scheme?.lowercased() == "https",
              url.host != nil, ["poster", "provided"].contains(variant) else { return }
        let destination = artRoot.appendingPathComponent(variant + "-" + id + ".jpg")
        guard !fm.fileExists(atPath: destination.path) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let data, data.count < 8_000_000,
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.savePoster(image, id: id, variant: variant)
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }.resume()
    }

    private func savePoster(_ image: UIImage, id: String, variant: String) {
        let destination = artRoot.appendingPathComponent(variant + "-" + id + ".jpg")
        guard !fm.fileExists(atPath: destination.path),
              image.size.width > 0, image.size.height > 0 else { return }
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
        try? data.write(to: destination, options: .atomic)
    }

    private func fetchMetadataPoster(for media: NativeStreamLink, id: String) {
        guard !posterLookups.contains(id),
              !fm.fileExists(atPath:
                artRoot.appendingPathComponent("poster-" + id + ".jpg").path)
        else { return }
        let rawIdentifiers = [media.contentId, media.videoId].compactMap { $0 }
        guard let imdb = rawIdentifiers.compactMap({ value -> String? in
            guard let match = value.range(of: #"tt[0-9]{5,12}"#,
                                          options: .regularExpression) else { return nil }
            return String(value[match])
        }).first else { return }
        posterLookups.insert(id)
        // Stremio's Cinemeta metadata endpoint accepts IMDb ids and returns
        // a poster URL. Avoid guessing from title strings or requiring API keys.
        let looksLikeSeries = (media.videoId ?? "").range(
            of: #":[0-9]+:[0-9]+$"#, options: .regularExpression) != nil
        let category = looksLikeSeries ? "series" : "movie"
        guard let endpoint = URL(string:
            "https://v3-cinemeta.strem.io/meta/" + category + "/" + imdb + ".json")
        else { return }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data, let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meta = json["meta"] as? [String: Any],
                  let poster = meta["poster"] as? String,
                  let posterURL = URL(string: poster) else { return }
            self.fetchArtwork(posterURL, id: id, variant: "poster")
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
    private let heading = UILabel()
    private let gallery = UIScrollView()
    private let tiles = UIStackView()
    private var cards: [String: NuvioHistoryTile] = [:]
    private var firstCard: UIButton?
    private var observer: NSObjectProtocol?

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        firstCard.map { [$0] } ?? []
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
        tiles.spacing = 38
        gallery.addSubview(tiles)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 60),
            heading.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 78),
            gallery.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 48),
            gallery.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 74),
            gallery.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -40),
            gallery.heightAnchor.constraint(equalToConstant: 515),
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
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        tiles.arrangedSubviews.forEach {
            tiles.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cards.removeAll()
        firstCard = nil
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
                    artwork: NuvioPlaybackLibrary.shared.artwork(for: item))
                card.onClick = { [weak self] in self?.onSelect?(item) }
                tiles.addArrangedSubview(card)
                cards[item.id] = card
                if firstCard == nil { firstCard = card }
            }
        }
    }

    private func refreshArtwork() {
        for item in NuvioPlaybackLibrary.shared.items {
            cards[item.id]?.updateArtwork(NuvioPlaybackLibrary.shared.artwork(for: item))
        }
    }
}

private final class NuvioHistoryTile: UIButton {
    var onClick: (() -> Void)?
    private let art = UIImageView()
    private let placeholder = UILabel()

    override var canBecomeFocused: Bool { true }

    init(item: NuvioHistoryItem, artwork: UIImage?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        clipsToBounds = false
        isUserInteractionEnabled = true
        widthAnchor.constraint(equalToConstant: 285).isActive = true
        heightAnchor.constraint(equalToConstant: 478).isActive = true
        accessibilityLabel = "Play " + item.title
        accessibilityTraits.insert(.button)

        let poster = UIView()
        poster.translatesAutoresizingMaskIntoConstraints = false
        poster.backgroundColor = UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 1)
        poster.layer.cornerRadius = 15
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

        let title = UILabel()
        let parts = item.videoId?.split(separator: ":") ?? []
        let episodeSuffix: String
        if parts.count >= 3,
           let season = Int(parts[parts.count - 2]),
           let episode = Int(parts[parts.count - 1]) {
            episodeSuffix = String(format: "  ·  S%02dE%02d", season, episode)
        } else {
            episodeSuffix = ""
        }
        title.text = item.title + episodeSuffix
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .white
        title.numberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false
        title.isUserInteractionEnabled = false
        addSubview(title)

        NSLayoutConstraint.activate([
            poster.leadingAnchor.constraint(equalTo: leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: trailingAnchor),
            poster.topAnchor.constraint(equalTo: topAnchor),
            poster.heightAnchor.constraint(equalToConstant: 422),
            art.leadingAnchor.constraint(equalTo: poster.leadingAnchor),
            art.trailingAnchor.constraint(equalTo: poster.trailingAnchor),
            art.topAnchor.constraint(equalTo: poster.topAnchor),
            art.bottomAnchor.constraint(equalTo: poster.bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: poster.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: poster.trailingAnchor, constant: -16),
            placeholder.centerYAnchor.constraint(equalTo: poster.centerYAnchor),
            title.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(equalTo: trailingAnchor),
            title.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
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
        updateArtwork(artwork)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func updateArtwork(_ image: UIImage?) {
        art.image = image
        placeholder.isHidden = image != nil
    }

    @objc private func tapped() { onClick?() }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({
            self.transform = self.isFocused
                ? CGAffineTransform(scaleX: 1.055, y: 1.055) : .identity
            self.layer.shadowColor = UIColor.white.cgColor
            self.layer.shadowOpacity = self.isFocused ? 0.42 : 0
            self.layer.shadowRadius = self.isFocused ? 18 : 0
            self.layer.shadowOffset = .zero
            self.layer.zPosition = self.isFocused ? 5 : 0
        })
    }
}
