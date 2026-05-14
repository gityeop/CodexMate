import Foundation

struct PendingDiscoveredThreadResolution: Equatable {
    let resolvedThreadIDs: Set<String>
    let missingThreadIDs: Set<String>
}

struct PendingDiscoveredThreadStore: Equatable {
    private(set) var observedAtByThreadID: [String: Date]
    private var retryAttemptCountByThreadID: [String: Int]
    private var lastRetryAtByThreadID: [String: Date]
    private let maxTrackedThreads: Int
    private let ttl: TimeInterval
    private let retryBackoffIntervals: [TimeInterval]

    init(
        observedAtByThreadID: [String: Date] = [:],
        maxTrackedThreads: Int = 64,
        ttl: TimeInterval = 2 * 60,
        retryBackoffIntervals: [TimeInterval] = [15, 30, 60]
    ) {
        self.observedAtByThreadID = observedAtByThreadID
        self.retryAttemptCountByThreadID = [:]
        self.lastRetryAtByThreadID = [:]
        self.maxTrackedThreads = max(1, maxTrackedThreads)
        self.ttl = max(1, ttl)
        let positiveRetryBackoffIntervals = retryBackoffIntervals.filter { $0 > 0 }
        self.retryBackoffIntervals = positiveRetryBackoffIntervals.isEmpty
            ? [15]
            : positiveRetryBackoffIntervals
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
            remove(threadID)
        }

        return PendingDiscoveredThreadResolution(
            resolvedThreadIDs: resolvedThreadIDs,
            missingThreadIDs: pendingThreadIDs.subtracting(resolvedThreadIDs)
        )
    }

    mutating func threadIDsReadyToRetry(_ threadIDs: Set<String>, now: Date = Date()) -> Set<String> {
        prune(now: now)

        return Set(threadIDs.filter { threadID in
            guard observedAtByThreadID[threadID] != nil else {
                return false
            }

            guard let lastRetryAt = lastRetryAtByThreadID[threadID] else {
                return true
            }

            let retryAttemptCount = retryAttemptCountByThreadID[threadID] ?? 0
            return now.timeIntervalSince(lastRetryAt) >= retryBackoffInterval(
                retryAttemptCount: retryAttemptCount
            )
        })
    }

    mutating func recordRetryAttempt(for threadIDs: Set<String>, now: Date = Date()) {
        prune(now: now)

        for threadID in threadIDs where observedAtByThreadID[threadID] != nil {
            lastRetryAtByThreadID[threadID] = now
            retryAttemptCountByThreadID[threadID, default: 0] += 1
        }
    }

    mutating func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        let expiredThreadIDs = Set(
            observedAtByThreadID.compactMap { threadID, observedAt in
                observedAt >= cutoff ? nil : threadID
            }
        )
        for threadID in expiredThreadIDs {
            remove(threadID)
        }
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

        let keptThreadIDSet = Set(keptThreadIDs)
        for threadID in pendingThreadIDs.subtracting(keptThreadIDSet) {
            remove(threadID)
        }
    }

    private mutating func remove(_ threadID: String) {
        observedAtByThreadID.removeValue(forKey: threadID)
        retryAttemptCountByThreadID.removeValue(forKey: threadID)
        lastRetryAtByThreadID.removeValue(forKey: threadID)
    }

    private func retryBackoffInterval(retryAttemptCount: Int) -> TimeInterval {
        let index = min(max(0, retryAttemptCount - 1), retryBackoffIntervals.count - 1)
        return retryBackoffIntervals[index]
    }
}
