/// A contiguous 12-second forward index. The previous coarse-first pass
/// deliberately left alternating thumbnail gaps (24s stride) visible when
/// the playback progress bar appeared. Advance one thumbnail bucket at a
/// time, regardless of whether the controls/seek preview are on screen.
struct NuvioAheadPlan {
    private(set) var cursor = 0
    private(set) var end = 0
    private var lastPlayback: Int?

    var hasPending: Bool { cursor < end }

    mutating func update(playback: Int, duration: Int) {
        // Start strictly ahead of the real playback position. Do not use
        // the uncommitted scrub cursor as an indexing anchor.
        let minimum = ((max(0, playback) + 12) / 12) * 12
        // A real seek reanchors the forward index. Ordinary time updates
        // must not reset the cursor or repeat already decoded slots.
        if lastPlayback == nil || abs(playback - (lastPlayback ?? playback)) > 20 {
            cursor = minimum
        }
        lastPlayback = playback
        end = max(0, duration - 1)
        cursor = max(cursor, minimum)
    }

    mutating func next() -> Int? {
        guard cursor < end else { return nil }
        let result = cursor
        cursor += 12
        return result
    }
}
