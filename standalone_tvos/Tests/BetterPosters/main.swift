import Foundation

func expect(_ actual: String?, _ expected: String?, line: Int = #line) {
    precondition(actual == expected,
                 "Better Posters test failed at line \(line): \(String(describing: actual))")
}

expect(NuvioBetterPosters.imdbID(contentId: "tt0903747", videoId: nil), "tt0903747")
expect(NuvioBetterPosters.imdbID(contentId: nil,
                                videoId: "tt0903747:5:12"), "tt0903747")
expect(NuvioBetterPosters.imdbID(contentId: "tmdb:1396",
                                videoId: "tt0903747:1:1"), "tt0903747")
expect(NuvioBetterPosters.imdbID(contentId: "tmdb:1396", videoId: nil), nil)
expect(NuvioBetterPosters.url(contentId: "tt0903747", videoId: nil)?.absoluteString,
       "https://btttr.cc/poster-q/imdb/poster-default/tt0903747.jpg?tag=none&rs=MC")
expect(NuvioBetterPosters.url(contentId: nil, videoId: nil)?.absoluteString, nil)
expect(NuvioBetterPosters.orderedVariants(isEpisode: true, hasSeasonArtwork: true).first,
       "season")
expect(NuvioBetterPosters.orderedVariants(isEpisode: false, hasSeasonArtwork: false).first,
       "better")
expect(NuvioBetterPosters.orderedVariants(isEpisode: true, hasSeasonArtwork: false).first,
       "better")
precondition(NuvioBetterPosters.orderedVariants(isEpisode: true, hasSeasonArtwork: true)
    .contains("provided"))
print("Better Posters history URL, identifiers, and precedence tests passed")
