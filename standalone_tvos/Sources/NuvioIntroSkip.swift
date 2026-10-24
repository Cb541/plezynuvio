import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Episode information from the *current* playback handoff. Never infer an
/// episode from the saved Resume position or a prior history selection.
struct NuvioEpisodeIdentity: Equatable {
    let imdbID: String
    let season: Int
    let episode: Int

    init?(imdbID: String?, season: Int?, episode: Int?) {
        guard let imdbID, let season, let episode,
              imdbID.range(of: #"^tt[0-9]{5,12}$"#, options: .regularExpression) != nil,
              (0...100).contains(season), (1...500).contains(episode) else { return nil }
        self.imdbID = imdbID
        self.season = season
        self.episode = episode
    }

    /// Nuvio/Stremio commonly sends videoId = "tt1234567:8:15" and
    /// contentId = "tt1234567". Explicit season/episode can also be passed.
    static func from(videoId: String?, contentId: String?,
                     imdbID: String? = nil, season: Int? = nil,
                     episode: Int? = nil) -> NuvioEpisodeIdentity? {
        let candidates = [videoId, contentId].compactMap { $0 }
        let suffix = candidates.compactMap { value -> (Int, Int)? in
            let parts = value.split(separator: ":")
            guard parts.count >= 3,
                  let season = Int(parts[parts.count - 2]),
                  let episode = Int(parts[parts.count - 1]) else { return nil }
            return (season, episode)
        }.first
        let id = imdbID ?? candidates.compactMap { value -> String? in
            guard let match = value.range(of: #"tt[0-9]{5,12}"#,
                                          options: .regularExpression) else { return nil }
            return String(value[match])
        }.first
        return NuvioEpisodeIdentity(imdbID: id, season: season ?? suffix?.0,
                                    episode: episode ?? suffix?.1)
    }
}

struct NuvioIntroWindow: Decodable, Equatable {
    let startSec: Double
    let endSec: Double

    private enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec = "end_sec"
    }

    var isValid: Bool {
        startSec.isFinite && endSec.isFinite && startSec >= 0 &&
        endSec > startSec && endSec - startSec <= 600
    }

    func contains(_ seconds: Double) -> Bool {
        isValid && seconds.isFinite && seconds >= startSec && seconds < endSec - 0.4
    }
}

private struct NuvioIntroDBSegments: Decodable {
    let intro: NuvioIntroWindow?
    let noIntro: Bool?

    enum CodingKeys: String, CodingKey {
        case intro
        case noIntro = "no_intro"
    }
}

/// IntroDB reads are anonymous. Never guess the intro if the database lacks
/// this particular episode or the lookup is unavailable.
enum NuvioIntroDB {
    static func decode(_ data: Data) -> NuvioIntroWindow? {
        guard let result = try? JSONDecoder().decode(NuvioIntroDBSegments.self, from: data),
              result.noIntro != true, let window = result.intro,
              window.isValid else { return nil }
        return window
    }

    static func lookup(_ episode: NuvioEpisodeIdentity) async -> NuvioIntroWindow? {
        var components = URLComponents(string: "https://api.introdb.app/segments")!
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: episode.imdbID),
            URLQueryItem(name: "season", value: String(episode.season)),
            URLQueryItem(name: "episode", value: String(episode.episode))
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return decode(data)
        } catch {
            return nil
        }
    }
}
