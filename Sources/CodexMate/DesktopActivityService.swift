import Foundation

struct ThreadSessionContext: Equatable {
    let path: String?
    let authoritativeUpdatedAt: Date?
    let authoritativeStatusIsPending: Bool
    let authoritativeStatusIsActive: Bool

    init(
        path: String?,
        authoritativeUpdatedAt: Date? = nil,
        authoritativeStatusIsPending: Bool = false,
        authoritativeStatusIsActive: Bool = false
    ) {
        self.path = path
        self.authoritativeUpdatedAt = authoritativeUpdatedAt
        self.authoritativeStatusIsPending = authoritativeStatusIsPending
        self.authoritativeStatusIsActive = authoritativeStatusIsActive
    }
}

struct DesktopActivityUpdate {
    let runtimeSnapshot: CodexDesktopRuntimeSnapshot?
    let latestViewedAtByThreadID: [String: Date]
    let latestTurnStartedAtByThreadID: [String: Date]
    let latestTurnCompletedAtByThreadID: [String: Date]
    let latestArchiveRequestedAtByThreadID: [String: Date]
    let latestUnarchiveRequestedAtByThreadID: [String: Date]
    let runtimeErrorMessage: String?

    init(
        runtimeSnapshot: CodexDesktopRuntimeSnapshot?,
        latestViewedAtByThreadID: [String: Date],
        latestTurnStartedAtByThreadID: [String: Date],
        latestTurnCompletedAtByThreadID: [String: Date],
        latestArchiveRequestedAtByThreadID: [String: Date] = [:],
        latestUnarchiveRequestedAtByThreadID: [String: Date] = [:],
        runtimeErrorMessage: String?
    ) {
        self.runtimeSnapshot = runtimeSnapshot
        self.latestViewedAtByThreadID = latestViewedAtByThreadID
        self.latestTurnStartedAtByThreadID = latestTurnStartedAtByThreadID
        self.latestTurnCompletedAtByThreadID = latestTurnCompletedAtByThreadID
        self.latestArchiveRequestedAtByThreadID = latestArchiveRequestedAtByThreadID
        self.latestUnarchiveRequestedAtByThreadID = latestUnarchiveRequestedAtByThreadID
        self.runtimeErrorMessage = runtimeErrorMessage
    }
}

actor DesktopActivityService {
    private enum RuntimeErrorPolicy {
        static let retryableOpenFailureAttempts = 2
        static let diagnosticThrottleInterval: TimeInterval = 30
        static let fallbackSnapshotReuseInterval: TimeInterval = 3
    }

    private struct FallbackSnapshotCacheEntry {
        let key: String
        let errorFingerprint: String
        let snapshot: CodexDesktopRuntimeSnapshot
        let cachedAt: Date
    }

    private let stateReader: CodexDesktopStateReader
    private let conversationActivityReader: CodexDesktopConversationActivityReader
    private let completionHintInterval: TimeInterval
    private let runningHintInterval: TimeInterval
    private var lastRuntimeErrorFingerprint: String?
    private var lastRuntimeErrorAt: Date?
    private var fallbackSnapshotCacheEntry: FallbackSnapshotCacheEntry?

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
            let trustedHintedRunningThreadIDs = suppressCompletedRunningHints(
                hintedRunningThreadIDs,
                activitySnapshot: activitySnapshot,
                latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
            )

            let combinedRunningThreadIDs = runtimeSnapshot.runningThreadIDs.union(trustedHintedRunningThreadIDs)
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
                latestArchiveRequestedAtByThreadID: activitySnapshot.latestArchiveRequestedAtByThreadID,
                latestUnarchiveRequestedAtByThreadID: activitySnapshot.latestUnarchiveRequestedAtByThreadID,
                runtimeErrorMessage: nil
            )
        } catch {
            let runtimeErrorMessage = throttledRuntimeErrorMessage(for: error, now: now)
            let errorFingerprint = runtimeErrorFingerprint(for: error)
            if let fallbackSnapshot = cachedFallbackSnapshot(
                for: candidateSessionContexts,
                errorFingerprint: errorFingerprint,
                now: now
            ) {
                let latestTurnCompletedAtByThreadID = mergeLatestDates(
                    activityLatestTurnCompletedAtByThreadID,
                    fallbackSnapshot.latestTurnCompletedAtByThreadID
                )
                let combinedFallbackSnapshot = snapshot(
                    fallbackSnapshot,
                    replacingLatestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
                )
                return DesktopActivityUpdate(
                    runtimeSnapshot: combinedFallbackSnapshot,
                    latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                    latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                    latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                    latestArchiveRequestedAtByThreadID: activitySnapshot.latestArchiveRequestedAtByThreadID,
                    latestUnarchiveRequestedAtByThreadID: activitySnapshot.latestUnarchiveRequestedAtByThreadID,
                    runtimeErrorMessage: nil
                )
            }

            if let fallbackSnapshot = stateReader.sessionFallbackSnapshot(
                candidateSessionContexts: candidateSessionContexts,
                databaseError: error.localizedDescription
            ) {
                storeFallbackSnapshot(
                    fallbackSnapshot,
                    for: candidateSessionContexts,
                    errorFingerprint: errorFingerprint,
                    now: now
                )
                DebugTraceLogger.log(
                    "desktop activity using session fallback candidates=\(candidateSessionContexts.count) message=\(error.localizedDescription)"
                )
                let latestTurnCompletedAtByThreadID = mergeLatestDates(
                    activityLatestTurnCompletedAtByThreadID,
                    fallbackSnapshot.latestTurnCompletedAtByThreadID
                )
                let combinedFallbackSnapshot = snapshot(
                    fallbackSnapshot,
                    replacingLatestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
                )
                return DesktopActivityUpdate(
                    runtimeSnapshot: combinedFallbackSnapshot,
                    latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                    latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                    latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
                    latestArchiveRequestedAtByThreadID: activitySnapshot.latestArchiveRequestedAtByThreadID,
                    latestUnarchiveRequestedAtByThreadID: activitySnapshot.latestUnarchiveRequestedAtByThreadID,
                    runtimeErrorMessage: nil
                )
            }
            return DesktopActivityUpdate(
                runtimeSnapshot: nil,
                latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
                latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
                latestTurnCompletedAtByThreadID: activityLatestTurnCompletedAtByThreadID,
                latestArchiveRequestedAtByThreadID: activitySnapshot.latestArchiveRequestedAtByThreadID,
                latestUnarchiveRequestedAtByThreadID: activitySnapshot.latestUnarchiveRequestedAtByThreadID,
                runtimeErrorMessage: runtimeErrorMessage
            )
        }
    }

    private func suppressCompletedRunningHints(
        _ runningThreadIDs: Set<String>,
        activitySnapshot: CodexDesktopConversationActivityReader.ActivitySnapshot,
        latestTurnCompletedAtByThreadID: [String: Date]
    ) -> Set<String> {
        Set(runningThreadIDs.filter { threadID in
            let startedAt = activitySnapshot.latestTurnStartedAtByThreadID[threadID] ?? .distantPast
            let completedAt = latestTurnCompletedAtByThreadID[threadID] ?? .distantPast
            return startedAt > completedAt
        })
    }

    private func snapshot(
        _ snapshot: CodexDesktopRuntimeSnapshot,
        replacingLatestTurnCompletedAtByThreadID latestTurnCompletedAtByThreadID: [String: Date]
    ) -> CodexDesktopRuntimeSnapshot {
        CodexDesktopRuntimeSnapshot(
            activeTurnCount: snapshot.activeTurnCount,
            runningThreadIDs: snapshot.runningThreadIDs,
            recentActivityThreadIDs: snapshot.recentActivityThreadIDs,
            waitingForInputThreadIDs: snapshot.waitingForInputThreadIDs,
            approvalThreadIDs: snapshot.approvalThreadIDs,
            failedThreads: snapshot.failedThreads,
            latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
            debugSummary: snapshot.debugSummary
        )
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
                fallbackSnapshotCacheEntry = nil
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

    private func cachedFallbackSnapshot(
        for candidateSessionContexts: [String: ThreadSessionContext],
        errorFingerprint: String,
        now: Date
    ) -> CodexDesktopRuntimeSnapshot? {
        guard let fallbackSnapshotCacheEntry,
              fallbackSnapshotCacheEntry.errorFingerprint == errorFingerprint,
              now.timeIntervalSince(fallbackSnapshotCacheEntry.cachedAt) < RuntimeErrorPolicy.fallbackSnapshotReuseInterval,
              fallbackSnapshotCacheEntry.key == fallbackSnapshotCacheKey(for: candidateSessionContexts)
        else {
            return nil
        }

        return fallbackSnapshotCacheEntry.snapshot
    }

    private func storeFallbackSnapshot(
        _ snapshot: CodexDesktopRuntimeSnapshot,
        for candidateSessionContexts: [String: ThreadSessionContext],
        errorFingerprint: String,
        now: Date
    ) {
        fallbackSnapshotCacheEntry = FallbackSnapshotCacheEntry(
            key: fallbackSnapshotCacheKey(for: candidateSessionContexts),
            errorFingerprint: errorFingerprint,
            snapshot: snapshot,
            cachedAt: now
        )
    }

    private func fallbackSnapshotCacheKey(for candidateSessionContexts: [String: ThreadSessionContext]) -> String {
        candidateSessionContexts
            .sorted(by: { $0.key < $1.key })
            .map { threadID, context in
                let authoritativeUpdatedAt = context.authoritativeUpdatedAt?.timeIntervalSince1970 ?? -1
                guard let rawPath = context.path else {
                    return "\(threadID)|path=nil|pending=\(context.authoritativeStatusIsPending)|active=\(context.authoritativeStatusIsActive)|updated=\(authoritativeUpdatedAt)"
                }

                let sessionURL = URL(fileURLWithPath: rawPath)
                let values = (try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) ?? URLResourceValues()
                let modificationDate = values.contentModificationDate?.timeIntervalSince1970 ?? -1
                let fileSize = values.fileSize ?? -1
                let exists = FileManager.default.fileExists(atPath: rawPath)

                return [
                    threadID,
                    rawPath,
                    "exists=\(exists)",
                    "mod=\(modificationDate)",
                    "size=\(fileSize)",
                    "pending=\(context.authoritativeStatusIsPending)",
                    "active=\(context.authoritativeStatusIsActive)",
                    "updated=\(authoritativeUpdatedAt)"
                ].joined(separator: "|")
            }
            .joined(separator: "||")
    }
}
