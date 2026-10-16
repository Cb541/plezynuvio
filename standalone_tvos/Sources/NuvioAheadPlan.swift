/// First cover future positions at 24-second intervals, then fill to 8 seconds.
/// This is independent of the seek UI and runs until both passes are complete.
struct NuvioAheadPlan {
    private(set) var cursor = 0
    private(set) var end = 0
    private var pass = 0
    private var lastPlayback: Int?
    private var floor = 0

    var hasPending: Bool { pass < 2 }

    mutating func update(playback: Int, duration: Int) {
        let minimum = ((max(0, playback) + 8) / 8) * 8
        if lastPlayback == nil || abs(playback - (lastPlayback ?? playback)) > 20 {
            pass = 0
            cursor = minimum
        }
        lastPlayback = playback
        floor = minimum
        end = max(0, duration - 1)
        cursor = max(cursor, floor)
    }

    mutating func next() -> Int? {
        while pass < 2 {
            if cursor >= end {
                pass += 1
                cursor = floor
                continue
            }
            let result = cursor
            cursor += pass == 0 ? 24 : 8
            return result
        }
        return nil
    }
}
