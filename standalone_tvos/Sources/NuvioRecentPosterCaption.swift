import Foundation

/// Labels beneath Recently Played artwork: none for movies, only "S4 Ep15"
/// for a Stremio-style series episode. Keep the full title available through
/// accessibility instead of placing it below the movie/episode poster.
enum NuvioRecentPosterCaption {
    static func episodeNumbers(videoId: String?) -> (season: Int, episode: Int)? {
        guard let videoId else { return nil }
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1]),
              (0...100).contains(season), (1...500).contains(episode)
        else { return nil }
        return (season, episode)
    }

    static func caption(videoId: String?) -> String? {
        guard let numbers = episodeNumbers(videoId: videoId) else { return nil }
        return "S\(numbers.season) Ep\(numbers.episode)"
    }
}
