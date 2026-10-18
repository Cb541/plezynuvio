import Foundation

/// Lightweight, optional Skip Intro metadata. Unlike offline audio
/// fingerprinting this does not download/decode other episodes and never
/// touches the active decoder, cached thumbnails or debrid stream URL.
struct IntroEpisodeDescriptor {
    let showName: String?
    let imdbID: String?
    let season: Int
    let episode: Int

    init?(title: String, showName: String? = nil, imdbID: String? = nil,
          season: Int? = nil, episode: Int? = nil) {
        var detectedSeason: Int?
        var detectedEpisode: Int?
        var nameFromTitle: String?
        let patterns = [
            #"(?i)\bS(\d{1,2})[ ._-]*E(\d{1,3})\b"#,
            #"(?i)\b(\d{1,2})x(\d{1,3})\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: title,
                    range: NSRange(title.startIndex..., in: title)),
                  let seasonRange = Range(match.range(at: 1), in: title),
                  let episodeRange = Range(match.range(at: 2), in: title)
            else { continue }
            detectedSeason = Int(title[seasonRange])
            detectedEpisode = Int(title[episodeRange])
            if let matchRange = Range(match.range, in: title) {
                nameFromTitle = String(title[..<matchRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet(
                        charactersIn: " .-_–—:([{"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            break
        }

        guard let s = season ?? detectedSeason, (0...99).contains(s),
              let e = episode ?? detectedEpisode, (1...999).contains(e)
        else { return nil }
        self.season = s
        self.episode = e

        if let id = imdbID, Self.isValidIMDbID(id) {
            self.imdbID = id.lowercased()
        } else {
            let imdbRegex = try? NSRegularExpression(pattern: #"(?i)\btt\d{7,10}\b"#)
            if let match = imdbRegex?.firstMatch(in: title,
                    range: NSRange(title.startIndex..., in: title)),
               let range = Range(match.range, in: title) {
                self.imdbID = String(title[range]).lowercased()
            } else {
                self.imdbID = nil
            }
        }
        let candidate = (showName?.isEmpty == false ? showName : nameFromTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.showName = (candidate?.count ?? 0) >= 2 && (candidate?.count ?? 0) <= 120
            ? candidate : nil
        if self.imdbID == nil && self.showName == nil { return nil }
    }

    static func isValidIMDbID(_ id: String) -> Bool {
        id.range(of: #"(?i)^tt\d{7,10}$"#, options: .regularExpression) != nil
    }

    static func normalizeTitle(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}

struct IntroTimeRange {
    let start: Double
    let end: Double

    func contains(_ playback: Double, duration: Double) -> Bool {
        guard playback.isFinite else { return false }
        return playback >= start && playback < end - 2
            && (duration <= 0 || end < duration - 3)
    }

    static func fromResponse(_ data: Data) -> IntroTimeRange? {
        guard let document = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
              let entry = document["intro"] as? [String: Any]
        else { return nil }
        func seconds(_ key: String) -> Double? {
            if let value = entry[key] as? NSNumber { return value.doubleValue }
            if let value = entry[key] as? String { return Double(value) }
            return nil
        }
        guard let start = seconds("start_sec"), let end = seconds("end_sec"),
              start.isFinite, end.isFinite,
              start >= 0, start <= 600, end >= start + 5,
              end <= 900, end - start <= 300
        else { return nil }
        // Prefer community-supported timestamps; never fabricate a duration.
        if let confidence = seconds("confidence"), confidence < 0.50 {
            return nil
        }
        return IntroTimeRange(start: start, end: end)
    }
}

final class IntroSkipService {
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ episode: IntroEpisodeDescriptor,
                 completion: @escaping (IntroTimeRange?) -> Void) {
        if let imdbID = episode.imdbID {
            queryIntroDB(imdbID: imdbID, season: episode.season,
                         episode: episode.episode, completion: completion)
            return
        }
        guard let show = episode.showName,
              let url = Self.endpoint(host: "api.tvmaze.com",
                    path: "/singlesearch/shows",
                    items: [URLQueryItem(name: "q", value: show)])
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        requestJSON(url) { [weak self] json in
            guard let self,
                  let showInfo = json,
                  let resultName = showInfo["name"] as? String,
                  // TVmaze is a fuzzy search. Avoid skipping the wrong show.
                  IntroEpisodeDescriptor.normalizeTitle(resultName)
                    == IntroEpisodeDescriptor.normalizeTitle(show),
                  let externals = showInfo["externals"] as? [String: Any],
                  let imdb = externals["imdb"] as? String,
                  IntroEpisodeDescriptor.isValidIMDbID(imdb)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.queryIntroDB(imdbID: imdb, season: episode.season,
                              episode: episode.episode, completion: completion)
        }
    }

    private func queryIntroDB(imdbID: String, season: Int, episode: Int,
                              completion: @escaping (IntroTimeRange?) -> Void) {
        guard let url = Self.endpoint(host: "api.introdb.app",
                path: "/segments", items: [
                    URLQueryItem(name: "imdb_id", value: imdbID),
                    URLQueryItem(name: "season", value: String(season)),
                    URLQueryItem(name: "episode", value: String(episode))
                ])
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, response, _ in
            let valid = (response as? HTTPURLResponse)?.statusCode == 200
            let range = valid ? data.flatMap(IntroTimeRange.fromResponse) : nil
            DispatchQueue.main.async { completion(range) }
        }.resume()
    }

    private func requestJSON(_ url: URL,
                             completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data)
                     as? [String: Any] else {
                completion(nil)
                return
            }
            completion(object)
        }.resume()
    }

    private static func endpoint(host: String, path: String,
                                 items: [URLQueryItem]) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = path
        parts.queryItems = items
        return parts.url
    }
}
