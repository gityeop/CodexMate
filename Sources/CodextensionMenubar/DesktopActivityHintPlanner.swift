import Foundation

struct DesktopActivityHintPlanner {
    static func latestTurnCompletedAtByThreadID(
        activitySnapshot: CodexDesktopConversationActivityReader.ActivitySnapshot,
        candidateThreadIDs: Set<String>,
        now: Date,
        completionHintInterval: TimeInterval
    ) -> [String: Date] {
        activitySnapshot.latestTurnCompletedAtByThreadID.reduce(into: [String: Date]()) { result, entry in
            let (threadID, completedAt) = entry
            let latestStartedAt = activitySnapshot.latestTurnStartedAtByThreadID[threadID] ?? .distantPast

            guard candidateThreadIDs.contains(threadID),
                  completedAt >= latestStartedAt,
                  now.timeIntervalSince(completedAt) <= completionHintInterval else {
                return
            }

            result[threadID] = completedAt
        }
    }

    static func hintedRunningThreadIDs(
        activitySnapshot: CodexDesktopConversationActivityReader.ActivitySnapshot,
        candidateThreadIDs: Set<String>,
        now: Date,
        runningHintInterval: TimeInterval
    ) -> Set<String> {
        var hintedRunningThreadIDs: Set<String> = []

        for (threadID, startedAt) in activitySnapshot.latestTurnStartedAtByThreadID {
            let completedAt = activitySnapshot.latestTurnCompletedAtByThreadID[threadID] ?? .distantPast
            guard candidateThreadIDs.contains(threadID),
                  startedAt > completedAt,
                  now.timeIntervalSince(startedAt) <= runningHintInterval else {
                continue
            }

            hintedRunningThreadIDs.insert(threadID)
        }

        return hintedRunningThreadIDs
    }
}
