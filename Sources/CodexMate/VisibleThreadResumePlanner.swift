import Foundation

struct ThreadSubscriptionPlan: Equatable {
    let targetThreadIDs: [String]
    let threadIDsToResume: [String]
    let threadIDsToUnsubscribe: [String]
}

struct ThreadSubscriptionPlanner {
    static func makePlan(
        targetThreadIDs: [String],
        liveThreadUpdatedAtByID: [String: Date]
    ) -> ThreadSubscriptionPlan {
        var seenThreadIDs: Set<String> = []
        let deduplicatedTargetThreadIDs = targetThreadIDs.filter { seenThreadIDs.insert($0).inserted }
        let targetThreadIDSet = Set(deduplicatedTargetThreadIDs)
        let liveThreadIDSet = Set(liveThreadUpdatedAtByID.keys)

        let threadIDsToResume = deduplicatedTargetThreadIDs.compactMap { threadID in
            liveThreadIDSet.contains(threadID) ? nil : threadID
        }

        let threadIDsToUnsubscribe = liveThreadUpdatedAtByID.keys
            .filter { !targetThreadIDSet.contains($0) }
            .sorted()

        return ThreadSubscriptionPlan(
            targetThreadIDs: deduplicatedTargetThreadIDs,
            threadIDsToResume: threadIDsToResume,
            threadIDsToUnsubscribe: threadIDsToUnsubscribe
        )
    }

    static func makePlan(
        recentThreads: [AppStateStore.ThreadRow],
        liveThreadUpdatedAtByID: [String: Date],
        maxSubscribedThreads: Int
    ) -> ThreadSubscriptionPlan {
        let targetThreads = Array(recentThreads.prefix(max(0, maxSubscribedThreads)))
        return makePlan(
            targetThreadIDs: targetThreads.map(\.id),
            liveThreadUpdatedAtByID: liveThreadUpdatedAtByID
        )
    }
}
