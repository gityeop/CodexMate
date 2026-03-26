import Foundation

struct DesktopActivityUpdate {
    let runtimeSnapshot: CodexDesktopRuntimeSnapshot?
    let latestViewedAtByThreadID: [String: Date]
    let latestTurnCompletedAtByThreadID: [String: Date]
    let runtimeErrorMessage: String?
}

actor DesktopActivityService {
    private enum RuntimeErrorPolicy {
        static let retryableOpenFailureAttempts = 2
        static let diagnosticThrottleInterval: TimeInterval = 30
    }

    private let stateReader: CodexDesktopStateReader
    private let conversationActivityReader: CodexDesktopConversationActivityReader
    private let completionHintInterval: TimeInterval
    private let runningHintInterval: TimeInterval
    private var lastRuntimeErrorFingerprint: String?
    private var lastRuntimeErrorAt: Date?

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
            let runtimeSnapshot = try loadRuntimeSnapshot(candidateSessionPaths: candidateSessionPaths)
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
                recentActivityThreadIDs: runtimeSnapshot.recentActivityThreadIDs,
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
            let runtimeErrorMessage = throttledRuntimeErrorMessage(for: error, now: now)
            return DesktopActivityUpdate(
                runtimeSnapshot: nil,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                runtimeErrorMessage: runtimeErrorMessage
            )
        }
    }

    private func loadRuntimeSnapshot(candidateSessionPaths: [String: String?]) throws -> CodexDesktopRuntimeSnapshot {
        var attempt = 0

        while true {
            do {
                let snapshot = try stateReader.snapshot(candidateSessionPaths: candidateSessionPaths)
                lastRuntimeErrorFingerprint = nil
                lastRuntimeErrorAt = nil
                return snapshot
            } catch let error as CodexDesktopStateReader.ReaderError
                where error.isRetriableDatabaseOpenFailure && attempt + 1 < RuntimeErrorPolicy.retryableOpenFailureAttempts {
                attempt += 1
                continue
            } catch {
                throw error
            }
        }
    }

    private func throttledRuntimeErrorMessage(for error: Error, now: Date) -> String? {
        let fingerprint = runtimeErrorFingerprint(for: error)
        if let lastRuntimeErrorFingerprint,
           lastRuntimeErrorFingerprint == fingerprint,
           let lastRuntimeErrorAt,
           now.timeIntervalSince(lastRuntimeErrorAt) < RuntimeErrorPolicy.diagnosticThrottleInterval {
            return nil
        }

        lastRuntimeErrorFingerprint = fingerprint
        lastRuntimeErrorAt = now

        if let readerError = error as? CodexDesktopStateReader.ReaderError,
           let databasePath = readerError.databasePath {
            DebugTraceLogger.log(
                "desktop activity state-db error path=\(databasePath) message=\(readerError.localizedDescription)"
            )
        }

        return error.localizedDescription
    }

    private func runtimeErrorFingerprint(for error: Error) -> String {
        if let readerError = error as? CodexDesktopStateReader.ReaderError {
            return [readerError.localizedDescription, readerError.databasePath ?? ""].joined(separator: "|")
        }

        return error.localizedDescription
    }
}
