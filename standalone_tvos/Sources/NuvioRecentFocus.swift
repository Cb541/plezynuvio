/// Deterministic adjacent-focus restoration after deleting a Recent poster.
/// Pure logic so it can be tested without UIKit on Linux and macOS.
enum NuvioRecentFocus {
    static func nextID(in orderedIDs: [String], removing id: String) -> String? {
        guard let index = orderedIDs.firstIndex(of: id) else { return nil }
        let remaining = orderedIDs.filter { $0 != id }
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)]
    }
}
