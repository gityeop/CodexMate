import Foundation

struct ThreadSessionContext: Equatable {
    let path: String?
    let authoritativeUpdatedAt: Date?
    let authoritativeStatusIsPending: Bool

    init(
        path: String?,
        authoritativeUpdatedAt: Date? = nil,
        authoritativeStatusIsPending: Bool = false
    ) {
        self.path = path
        self.authoritativeUpdatedAt = authoritativeUpdatedAt
        self.authoritativeStatusIsPending = authoritativeStatusIsPending
    }
}

struct DesktopActivityUpdate {
    let runtimeSnapshot: CodexDesktopRuntimeSnapshot?
    let latestViewedAtByThreadID: [String: Date]
    let latestTurnStartedAtByThreadID: [String: Date]
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
        stateReader: CodexDesktopStateReader? = nil,
        conversationActivityReader: CodexDesktopConversationActivityReader = .init(),
        codexDirectoryURLProvider: (@Sendable () -> URL)? = nil,
        completionHintInterval: TimeInterval = 30 * 60,
        runningHintInterval: TimeInterval = 15
    ) {
        self.stateReader = stateReader ?? CodexDesktopStateReader(
            codexDirectoryURLProvider: codexDirectoryURLProvider
        )
        self.conversationActivityReader = conversationActivityReader
        self.completionHintInterval = completionHintInterval
        self.runningHintInterval = runningHintInterval
    }

    func load(candidateSessionContexts: [String: ThreadSessionContext], now: Date = Date()) -> DesktopActivityUpdate {
        let activitySnapshot = conversationActivityReader.activitySnapshot(now: now)
        let candidateThreadIDs = Set(candidateSessionContexts.keys)

        let activityLatestTurnCompletedAtByThreadID = DesktopActivityHintPlanner.latestTurnCompletedAtByThreadID(
            activitySnapshot: activitySnapshot,
            candidateThreadIDs: candidateThreadIDs,
            now: now,
            completionHintInterval: completionHintInterval
        )

        do {
            let runtimeSnapshot = try loadRuntimeSnapshot(candidateSessionContexts: candidateSessionContexts)
            let latestTurnCompletedAtByThreadID = mergeLatestDates(
                activityLatestTurnCompletedAtByThreadID,
                runtimeSnapshot.latestTurnCompletedAtByThreadID
            )
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
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                debugSummary: runtimeSnapshot.debugSummary
            )

            return DesktopActivityUpdate(
                runtimeSnapshot: combinedSnapshot,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                runtimeErrorMessage: nil
            )
        } catch {
            let runtimeErrorMessage = throttledRuntimeErrorMessage(for: error, now: now)
            if let fallbackSnapshot = stateReader.sessionFallbackSnapshot(
                candidateSessionContexts: candidateSessionContexts,
                databaseError: error.localizedDescription
            ) {
                DebugTraceLogger.log(
                    "desktop activity using session fallback candidates=\(candidateSessionContexts.count) message=\(error.localizedDescription)"
                )
                return DesktopActivityUpdate(
                    runtimeSnapshot: fallbackSnapshot,
                    latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                    latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                    latestTurnCompletedAtByThreadID: activityLatestTurnCompletedAtByThreadID,
                    runtimeErrorMessage: nil
                )
            }
            return DesktopActivityUpdate(
                runtimeSnapshot: nil,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                latestTurnCompletedAtByThreadID: activityLatestTurnCompletedAtByThreadID,
                runtimeErrorMessage: runtimeErrorMessage
            )
        }
    }

    func load(candidateSessionPaths: [String: String?], now: Date = Date()) -> DesktopActivityUpdate {
        load(
            candidateSessionContexts: candidateSessionPaths.mapValues { ThreadSessionContext(path: $0) },
            now: now
        )
    }

    private func mergeLatestDates(_ lhs: [String: Date], _ rhs: [String: Date]) -> [String: Date] {
        var merged = lhs
        for (threadID, date) in rhs {
            if date > (merged[threadID] ?? .distantPast) {
                merged[threadID] = date
            }
        }

        return merged
    }

    private func loadRuntimeSnapshot(candidateSessionContexts: [String: ThreadSessionContext]) throws -> CodexDesktopRuntimeSnapshot {
        var attempt = 0

        while true {
            do {
                let snapshot = try stateReader.snapshot(candidateSessionContexts: candidateSessionContexts)
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
