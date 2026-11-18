/// Memory-bounded, session-local LRU. Callers serialize access.
struct NuvioPreviewLRU<Value> {
    private var values: [Int: (value: Value, cost: Int)] = [:]
    private var order: [Int] = []
    private(set) var bytes = 0
    let maxCount: Int
    let maxBytes: Int

    var keys: Set<Int> { Set(values.keys) }
    func contains(_ key: Int) -> Bool { values[key] != nil }

    mutating func get(_ key: Int) -> Value? {
        guard let entry = values[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    mutating func put(_ value: Value, key: Int, cost: Int) {
        let boundedCost = max(1, cost)
        if let prior = values.removeValue(forKey: key) { bytes -= prior.cost }
        order.removeAll { $0 == key }
        guard maxCount > 0, boundedCost <= maxBytes else { return }
        values[key] = (value, boundedCost)
        order.append(key)
        bytes += boundedCost
        while order.count > maxCount || bytes > maxBytes {
            guard !order.isEmpty else { break }
            let oldest = order.removeFirst()
            if let old = values.removeValue(forKey: oldest) { bytes -= old.cost }
        }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
        bytes = 0
    }
}
