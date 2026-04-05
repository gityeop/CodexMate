import Foundation

struct ThreadActivityRefreshPlanner {
    static func discoveredThreadIDsNeedingRefresh(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date],
        recentActivityThreadIDs: Set<String> = [],
        attentionThreadIDs: Set<String> = [],
        now: Date = Date(),
        discoveryLookbackInterval: TimeInterval = 90
    ) -> Set<String> {
        recentActivityThreadIDs
            .union(attentionThreadIDs)
            .subtracting(recentThreadIDs)
    }

    static func shouldRefreshThreads(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date],
        recentActivityThreadIDs: Set<String> = [],
        attentionThreadIDs: Set<String> = [],
        now: Date = Date(),
        discoveryLookbackInterval: TimeInterval = 90
    ) -> Bool {
        !discoveredThreadIDsNeedingRefresh(
            recentThreadIDs: recentThreadIDs,
            latestViewedAtByThreadID: latestViewedAtByThreadID,
            recentActivityThreadIDs: recentActivityThreadIDs,
            attentionThreadIDs: attentionThreadIDs,
            now: now,
            discoveryLookbackInterval: discoveryLookbackInterval
        ).isEmpty
    }
}
