import Foundation

struct DesktopActivityUpdate {
    let runtimeSnapshot: CodexDesktopRuntimeSnapshot?
    let latestViewedAtByThreadID: [String: Date]
    let latestTurnCompletedAtByThreadID: [String: Date]
    let runtimeErrorMessage: String?
}

actor DesktopActivityService {
    private let stateReader: CodexDesktopStateReader
    private let conversationActivityReader: CodexDesktopConversationActivityReader
    private let runningHintInterval: TimeInterval

    init(
        stateReader: CodexDesktopStateReader = .init(),
        conversationActivityReader: CodexDesktopConversationActivityReader = .init(),
        runningHintInterval: TimeInterval = 30 * 60
    ) {
        self.stateReader = stateReader
        self.conversationActivityReader = conversationActivityReader
        self.runningHintInterval = runningHintInterval
    }

    func load(candidateSessionPaths: [String: String?], now: Date = Date()) -> DesktopActivityUpdate {
        let activitySnapshot = conversationActivityReader.activitySnapshot(now: now)
        let candidateThreadIDs = Set(candidateSessionPaths.keys)

        let latestTurnCompletedAtByThreadID = activitySnapshot.latestTurnCompletedAtByThreadID.reduce(into: [String: Date]()) { result, entry in
            let (threadID, completedAt) = entry
            let latestStartedAt = activitySnapshot.latestTurnStartedAtByThreadID[threadID] ?? .distantPast

            guard candidateThreadIDs.contains(threadID),
                  completedAt >= latestStartedAt,
                  now.timeIntervalSince(completedAt) <= runningHintInterval else {
                return
            }

            result[threadID] = completedAt
        }

        do {
            let runtimeSnapshot = try stateReader.snapshot(candidateSessionPaths: candidateSessionPaths)
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

            let combinedRunningThreadIDs = runtimeSnapshot.runningThreadIDs.union(hintedRunningThreadIDs)
            let combinedActiveTurnCount: Int
            if combinedRunningThreadIDs.isEmpty && !latestTurnCompletedAtByThreadID.isEmpty {
                combinedActiveTurnCount = 0
            } else {
                combinedActiveTurnCount = max(runtimeSnapshot.activeTurnCount, combinedRunningThreadIDs.isEmpty ? 0 : 1)
            }

            let combinedSnapshot = CodexDesktopRuntimeSnapshot(
                activeTurnCount: combinedActiveTurnCount,
                runningThreadIDs: combinedRunningThreadIDs,
                waitingForInputThreadIDs: runtimeSnapshot.waitingForInputThreadIDs,
                approvalThreadIDs: runtimeSnapshot.approvalThreadIDs,
                failedThreads: runtimeSnapshot.failedThreads,
                debugSummary: runtimeSnapshot.debugSummary
            )

            return DesktopActivityUpdate(
                runtimeSnapshot: combinedSnapshot,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                runtimeErrorMessage: nil
            )
        } catch {
            return DesktopActivityUpdate(
                runtimeSnapshot: nil,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                runtimeErrorMessage: error.localizedDescription
            )
        }
    }
}
