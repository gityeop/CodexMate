import Foundation

struct ThreadActivityRefreshPlanner {
    static func discoveredThreadIDsNeedingRefresh(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date],
        recentActivityThreadIDs: Set<String> = [],
        now: Date = Date(),
        discoveryLookbackInterval: TimeInterval = 90
    ) -> Set<String> {
        let stateDiscoveredThreadIDs = recentActivityThreadIDs.subtracting(recentThreadIDs)
        return stateDiscoveredThreadIDs
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
