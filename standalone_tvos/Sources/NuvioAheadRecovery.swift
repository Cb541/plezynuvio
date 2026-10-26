/// Independent scheduling policy for missed native playback captures and
/// interrupted FFmpeg ahead decodes. This file has no UIKit/AVFoundation
/// dependencies so its fairness and slot math can be tested on Linux.
struct NuvioAheadRecovery {
    /// Preserve the fast 24-second forward pass: only one recovery request
    /// for every four new forward requests while there is forward work.
    private(set) var forwardJobsSinceRepair = 0
    static let forwardQuota = 4
    static let lookbackSeconds = 240

    mutating func reset() {
        forwardJobsSinceRepair = 0
    }

    var shouldRepairBeforeForward: Bool {
        forwardJobsSinceRepair >= Self.forwardQuota
    }

    mutating func didScheduleForward() {
        forwardJobsSinceRepair = min(Self.forwardQuota, forwardJobsSinceRepair + 1)
    }

    mutating func didScheduleRepair() {
        forwardJobsSinceRepair = 0
    }

    /// Only look behind the playback head. Give the normal native decoded-
    /// frame tap the entire 12-second bucket before declaring a hole; this
    /// avoids double decoding frames still about to be captured by playback.
    static func completedPastSlots(playback: Int) -> [Int] {
        let last = (max(0, playback - 12) / 12) * 12
        guard last >= 12 else { return [] }
        let first = max(12, ((max(0, playback - lookbackSeconds) + 11) / 12) * 12)
        guard first <= last else { return [] }
        return Array(stride(from: first, through: last, by: 12))
    }
}
