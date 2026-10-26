import Foundation

func verify(_ videoId: String?, _ expected: String?, file: StaticString = #file,
            line: UInt = #line) {
    let actual = NuvioRecentPosterCaption.caption(videoId: videoId)
    precondition(actual == expected, "Expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
}

// Movies never show their title or an episode label beneath their poster.
verify("tt0133093", nil)
verify(nil, nil)
verify("tmdb:603", nil)
// Episodes use the requested human-readable compact format without zero padding.
verify("tt0944947:4:15", "S4 Ep15")
verify("tt0944947:1:1", "S1 Ep1")
verify("tt0944947:0:2", "S0 Ep2")
verify("tt0944947:10:125", "S10 Ep125")
verify("tt0944947:4:0", nil)
verify("tt0944947:101:1", nil)
verify("tt0944947:abc:5", nil)
print("Recently Played poster caption tests passed")
