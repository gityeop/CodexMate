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
    private let completionHintInterval: TimeInterval
    private let runningHintInterval: TimeInterval

    init(
        stateReader: CodexDesktopStateReader = .init(),
        conversationActivityReader: CodexDesktopConversationActivityReader = .init(),
        completionHintInterval: TimeInterval = 30 * 60,
        runningHintInterval: TimeInterval = 15
    ) {
        self.stateReader = stateReader
        self.conversationActivityReader = conversationActivityReader
        self.completionHintInterval = completionHintInterval
        self.runningHintInterval = runningHintInterval
    }

    func load(candidateSessionPaths: [String: String?], now: Date = Date()) -> DesktopActivityUpdate {
        let activitySnapshot = conversationActivityReader.activitySnapshot(now: now)
        let candidateThreadIDs = Set(candidateSessionPaths.keys)

        let latestTurnCompletedAtByThreadID = DesktopActivityHintPlanner.latestTurnCompletedAtByThreadID(
            activitySnapshot: activitySnapshot,
            candidateThreadIDs: candidateThreadIDs,
            now: now,
            completionHintInterval: completionHintInterval
        )

        do {
            let runtimeSnapshot = try stateReader.snapshot(candidateSessionPaths: candidateSessionPaths)
            let hintedRunningThreadIDs = DesktopActivityHintPlanner.hintedRunningThreadIDs(
                activitySnapshot: activitySnapshot,
                candidateThreadIDs: candidateThreadIDs,
                now: now,
                runningHintInterval: runningHintInterval
            )

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
