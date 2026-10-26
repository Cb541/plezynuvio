import Foundation

/// The user's Better Posters pattern already used by Nuvio. A single, public
/// IMDb-based artwork URL works for both movies and the series associated with
/// a Stremio episode ID. No private keys or playback URLs are sent to it.
enum NuvioBetterPosters {
    static let template =
        "https://btttr.cc/poster-q/imdb/poster-default/{imdb_id}.jpg?tag=none&rs=MC"

    static func imdbID(contentId: String?, videoId: String?) -> String? {
        for raw in [contentId, videoId].compactMap({ $0 }) {
            guard let match = raw.range(of: #"tt[0-9]{5,12}"#,
                                        options: .regularExpression) else { continue }
            return String(raw[match])
        }
        return nil
    }

    static func url(contentId: String?, videoId: String?) -> URL? {
        guard let imdbID = imdbID(contentId: contentId, videoId: videoId) else {
            return nil
        }
        return URL(string: template.replacingOccurrences(
            of: "{imdb_id}", with: imdbID))
    }

    /// Don't replace a season-specific TMDB poster with the generic series
    /// image. Otherwise Better Posters wins over Stremio/Cinemeta art, with
    /// the same existing fallback chain as before.
    static func orderedVariants(isEpisode: Bool,
                                hasSeasonArtwork: Bool) -> [String] {
        if isEpisode && hasSeasonArtwork {
            return ["season", "better", "poster", "provided", "episode"]
        }
        return ["better", "poster", "provided", "episode"]
    }
}
