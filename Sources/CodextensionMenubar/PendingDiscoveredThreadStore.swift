import Foundation

struct PendingDiscoveredThreadResolution: Equatable {
    let resolvedThreadIDs: Set<String>
    let missingThreadIDs: Set<String>
}

struct PendingDiscoveredThreadStore: Equatable {
    private(set) var observedAtByThreadID: [String: Date]
    private let maxTrackedThreads: Int
    private let ttl: TimeInterval

    init(
        observedAtByThreadID: [String: Date] = [:],
        maxTrackedThreads: Int = 64,
        ttl: TimeInterval = 2 * 60
    ) {
        self.observedAtByThreadID = observedAtByThreadID
        self.maxTrackedThreads = max(1, maxTrackedThreads)
        self.ttl = max(1, ttl)
    }

    var pendingThreadIDs: Set<String> {
        Set(observedAtByThreadID.keys)
    }

    var hasPendingThreads: Bool {
        !observedAtByThreadID.isEmpty
    }

    mutating func observe(_ threadIDs: Set<String>, now: Date = Date()) -> Set<String> {
        prune(now: now)

        guard !threadIDs.isEmpty else {
            return []
        }

        var newThreadIDs: Set<String> = []
        for threadID in threadIDs {
            if observedAtByThreadID.updateValue(now, forKey: threadID) == nil {
                newThreadIDs.insert(threadID)
            }
        }

        trimToBudget()
        return newThreadIDs.intersection(pendingThreadIDs)
    }

    mutating func resolve(with fetchedThreadIDs: Set<String>, now: Date = Date()) -> PendingDiscoveredThreadResolution {
        prune(now: now)

        let resolvedThreadIDs = pendingThreadIDs.intersection(fetchedThreadIDs)
        for threadID in resolvedThreadIDs {
            observedAtByThreadID.removeValue(forKey: threadID)
        }

        return PendingDiscoveredThreadResolution(
            resolvedThreadIDs: resolvedThreadIDs,
            missingThreadIDs: pendingThreadIDs.subtracting(resolvedThreadIDs)
        )
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        observedAtByThreadID = observedAtByThreadID.filter { $0.value >= cutoff }
        trimToBudget()
    }

    private mutating func trimToBudget() {
        guard observedAtByThreadID.count > maxTrackedThreads else {
            return
        }

        let keptThreadIDs = observedAtByThreadID
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }

                return lhs.value > rhs.value
            }
            .prefix(maxTrackedThreads)
            .map(\.key)

        observedAtByThreadID = observedAtByThreadID.filter { keptThreadIDs.contains($0.key) }
    }
}
