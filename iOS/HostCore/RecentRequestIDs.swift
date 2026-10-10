import Foundation

/// The bounded `knownRequestIDs` set the reconciler consults: every request this run admitted or
/// rejected, plus those recovered from the previous run. The oldest IDs fall out first; by then their
/// record intents are long past `pendingRecordTTL`, so forgetting them cannot restart anything.
struct RecentRequestIDs: Equatable, Sendable {
    static let defaultCapacity = 32

    let capacity: Int
    private(set) var ordered: [UUID] = []   // oldest first

    init<IDs: Sequence>(capacity: Int = defaultCapacity, _ ids: IDs) where IDs.Element == UUID {
        self.capacity = max(1, capacity)
        for id in ids { insert(id) }
    }

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var set: Set<UUID> { Set(ordered) }

    func contains(_ id: UUID) -> Bool { ordered.contains(id) }

    /// Adds `id` as the newest entry, moving it there if it was already known.
    mutating func insert(_ id: UUID) {
        ordered.removeAll { $0 == id }
        ordered.append(id)
        if ordered.count > capacity { ordered.removeFirst(ordered.count - capacity) }
    }
}
