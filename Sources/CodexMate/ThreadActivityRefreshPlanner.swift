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
        let discoveryCutoff = now.addingTimeInterval(-discoveryLookbackInterval)
        let recentlyViewedUnknownThreadIDs: Set<String> = Set(
            latestViewedAtByThreadID.compactMap { entry in
                let (threadID, viewedAt) = entry
                guard viewedAt >= discoveryCutoff,
                      !recentThreadIDs.contains(threadID) else {
                    return nil
                }

                return threadID
            }
        )

        return recentActivityThreadIDs
            .union(attentionThreadIDs)
            .union(recentlyViewedUnknownThreadIDs)
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
