import Foundation

struct ThreadActivityRefreshPlanner {
    static func discoveredThreadIDsNeedingRefresh(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date],
        recentActivityThreadIDs: Set<String> = [],
        now: Date = Date(),
        discoveryLookbackInterval: TimeInterval = 90
    ) -> Set<String> {
        let cutoff = now.addingTimeInterval(-max(1, discoveryLookbackInterval))
        let stateDiscoveredThreadIDs = recentActivityThreadIDs.subtracting(recentThreadIDs)

        let viewedDiscoveredThreadIDs = Set<String>(
            latestViewedAtByThreadID.compactMap { threadID, viewedAt in
                guard !recentThreadIDs.contains(threadID), viewedAt >= cutoff else {
                    return nil
                }

                return threadID
            }
        )

        return stateDiscoveredThreadIDs.union(viewedDiscoveredThreadIDs)
    }

    static func shouldRefreshThreads(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date],
        recentActivityThreadIDs: Set<String> = [],
        now: Date = Date(),
        discoveryLookbackInterval: TimeInterval = 90
    ) -> Bool {
        !discoveredThreadIDsNeedingRefresh(
            recentThreadIDs: recentThreadIDs,
            latestViewedAtByThreadID: latestViewedAtByThreadID,
            recentActivityThreadIDs: recentActivityThreadIDs,
            now: now,
            discoveryLookbackInterval: discoveryLookbackInterval
        ).isEmpty
    }
}
