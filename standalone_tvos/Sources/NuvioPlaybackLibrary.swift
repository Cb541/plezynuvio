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
        if let url = media.artworkURL { fetchArtwork(url, id: id) }
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
        UIImage(contentsOfFile: artRoot.appendingPathComponent(entry.id + ".jpg").path)
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

    private func fetchArtwork(_ url: URL, id: String) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        let dest = artRoot.appendingPathComponent(id + ".jpg")
        guard !fm.fileExists(atPath: dest.path) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self, let data, data.count < 3_000_000,
                  let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.saveArtwork(image, id: id, onlyIfAbsent: true)
                NotificationCenter.default.post(name: Self.changed, object: nil)
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

/// Separate idle screen: no decoder or seek-frame cache is allocated for this view.
final class NuvioHistoryHomeView: UIView {
    var onSelect: ((NuvioHistoryItem) -> Void)?
    private let scroll = UIScrollView()
    private let column = UIStackView()
    private var observer: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.025, green: 0.025, blue: 0.045, alpha: 1)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 38
        addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 72),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -60),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        observer = NotificationCenter.default.addObserver(
            forName: NuvioPlaybackLibrary.changed, object: nil,
            queue: .main) { [weak self] _ in
                guard let self, !self.isHidden else { return }
                self.reload()
            }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let heading = UILabel()
        heading.text = "NUVIO PLAYER"
        heading.textColor = .white
        heading.font = .systemFont(ofSize: 48, weight: .bold)
        column.addArrangedSubview(heading)

        let all = NuvioPlaybackLibrary.shared.items
        let incomplete = all.filter(\.isInProgress)
        if !incomplete.isEmpty { addRow("Continue Watching", entries: Array(incomplete.prefix(20))) }
        if !all.isEmpty {
            addRow("Recently Played", entries: Array(all.prefix(30)))
        } else {
            let hint = UILabel()
            hint.text = "Open a movie or episode from Nuvio to get started."
            hint.font = .systemFont(ofSize: 27, weight: .medium)
            hint.textColor = .lightGray
            column.addArrangedSubview(hint)
        }
    }

    private func addRow(_ title: String, entries: [NuvioHistoryItem]) {
        let group = UIStackView()
        group.axis = .vertical
        group.spacing = 20
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 29, weight: .semibold)
        group.addArrangedSubview(label)

        let horizontal = UIScrollView()
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        horizontal.heightAnchor.constraint(equalToConstant: 215).isActive = true
        horizontal.showsHorizontalScrollIndicator = false
        let tiles = UIStackView()
        tiles.axis = .horizontal
        tiles.spacing = 22
        tiles.translatesAutoresizingMaskIntoConstraints = false
        horizontal.addSubview(tiles)
        NSLayoutConstraint.activate([
            tiles.topAnchor.constraint(equalTo: horizontal.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: horizontal.contentLayoutGuide.bottomAnchor),
            tiles.leadingAnchor.constraint(equalTo: horizontal.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: horizontal.contentLayoutGuide.trailingAnchor),
            tiles.heightAnchor.constraint(equalTo: horizontal.frameLayoutGuide.heightAnchor)
        ])
        for item in entries {
            let button = NuvioHistoryTile(item: item,
                image: NuvioPlaybackLibrary.shared.artwork(for: item))
            button.onClick = { [weak self] in self?.onSelect?(item) }
            tiles.addArrangedSubview(button)
        }
        group.addArrangedSubview(horizontal)
        column.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
}

private final class NuvioHistoryTile: UIButton {
    var onClick: (() -> Void)?
    private let art = UIImageView()

    init(item: NuvioHistoryItem, image: UIImage?) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 1)
        layer.cornerRadius = 17
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 310).isActive = true
        heightAnchor.constraint(equalToConstant: 188).isActive = true
        art.translatesAutoresizingMaskIntoConstraints = false
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.image = image
        addSubview(art)
        let name = UILabel()
        let segments = item.videoId?.split(separator: ":") ?? []
        let episodeLabel: String
        if segments.count >= 3,
           let season = Int(segments[segments.count - 2]),
           let episode = Int(segments[segments.count - 1]) {
            episodeLabel = String(format: " · S%02dE%02d", season, episode)
        } else {
            episodeLabel = ""
        }
        name.text = item.title + episodeLabel
        name.font = .systemFont(ofSize: 19, weight: .semibold)
        name.textColor = .white
        name.backgroundColor = UIColor.black.withAlphaComponent(0.66)
        name.numberOfLines = 2
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo: topAnchor),
            art.bottomAnchor.constraint(equalTo: bottomAnchor),
            art.leadingAnchor.constraint(equalTo: leadingAnchor),
            art.trailingAnchor.constraint(equalTo: trailingAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        if item.isInProgress {
            let track = UIView()
            track.backgroundColor = .darkGray
            track.translatesAutoresizingMaskIntoConstraints = false
            let fill = UIView()
            fill.backgroundColor = .white
            fill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(track)
            track.addSubview(fill)
            NSLayoutConstraint.activate([
                track.leadingAnchor.constraint(equalTo: leadingAnchor),
                track.trailingAnchor.constraint(equalTo: trailingAnchor),
                track.bottomAnchor.constraint(equalTo: bottomAnchor),
                track.heightAnchor.constraint(equalToConstant: 4),
                fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                fill.topAnchor.constraint(equalTo: track.topAnchor),
                fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
                fill.widthAnchor.constraint(equalTo: track.widthAnchor,
                    multiplier: CGFloat(min(1, max(0, item.position / item.duration))))
            ])
        }
        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    @objc private func tapped() { onClick?() }
    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        coordinator.addCoordinatedAnimations({
            self.transform = self.isFocused
                ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
            self.layer.borderWidth = self.isFocused ? 3 : 0
            self.layer.borderColor = UIColor.white.cgColor
        })
    }
}
