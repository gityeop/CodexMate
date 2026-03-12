import Foundation

struct ThreadSubscriptionPlan: Equatable {
    let targetThreadIDs: [String]
    let threadIDsToResume: [String]
    let threadIDsToUnsubscribe: [String]
}

struct ThreadSubscriptionPlanner {
    static func makePlan(
        recentThreads: [AppStateStore.ThreadRow],
        liveThreadUpdatedAtByID: [String: Date],
        maxSubscribedThreads: Int
    ) -> ThreadSubscriptionPlan {
        let targetThreads = Array(recentThreads.prefix(max(0, maxSubscribedThreads)))
        let targetThreadIDs = targetThreads.map(\.id)
        let targetThreadIDSet = Set(targetThreadIDs)
        let liveThreadIDSet = Set(liveThreadUpdatedAtByID.keys)

        let threadIDsToResume = targetThreads.compactMap { thread in
            liveThreadIDSet.contains(thread.id) ? nil : thread.id
        }

        let threadIDsToUnsubscribe = liveThreadUpdatedAtByID.keys
            .filter { !targetThreadIDSet.contains($0) }
            .sorted()

        return ThreadSubscriptionPlan(
            targetThreadIDs: targetThreadIDs,
            threadIDsToResume: threadIDsToResume,
            threadIDsToUnsubscribe: threadIDsToUnsubscribe
        )
    }
}
