import Foundation

struct ThreadActivityRefreshPlanner {
    static func shouldRefreshThreads(
        recentThreadIDs: Set<String>,
        latestViewedAtByThreadID: [String: Date]
    ) -> Bool {
        latestViewedAtByThreadID.keys.contains { threadID in
            !recentThreadIDs.contains(threadID)
        }
    }
}
