import Foundation

struct CodexDesktopRuntimeSnapshot {
    struct FailedThreadState {
        let message: String
        let loggedAt: Date
    }

    let activeTurnCount: Int
    let runningThreadIDs: Set<String>
    let recentActivityThreadIDs: Set<String>
    let waitingForInputThreadIDs: Set<String>
    let approvalThreadIDs: Set<String>
    let failedThreads: [String: FailedThreadState]
    let latestTurnCompletedAtByThreadID: [String: Date]
    let debugSummary: String

    init(
        activeTurnCount: Int,
        runningThreadIDs: Set<String>,
        recentActivityThreadIDs: Set<String> = [],
        waitingForInputThreadIDs: Set<String> = [],
        approvalThreadIDs: Set<String> = [],
        failedThreads: [String: FailedThreadState] = [:],
        latestTurnCompletedAtByThreadID: [String: Date] = [:],
        debugSummary: String = ""
    ) {
        self.activeTurnCount = activeTurnCount
        self.runningThreadIDs = runningThreadIDs
        self.recentActivityThreadIDs = recentActivityThreadIDs
        self.waitingForInputThreadIDs = waitingForInputThreadIDs
        self.approvalThreadIDs = approvalThreadIDs
        self.failedThreads = failedThreads
        self.latestTurnCompletedAtByThreadID = latestTurnCompletedAtByThreadID
        self.debugSummary = debugSummary
    }
}

struct CodexDesktopStateReader {
    struct SessionPendingState: Equatable {
        let waitingForInput: Bool
        let needsApproval: Bool
        let hasActiveTask: Bool

        init(waitingForInput: Bool, needsApproval: Bool, hasActiveTask: Bool = false) {
            self.waitingForInput = waitingForInput
            self.needsApproval = needsApproval
            self.hasActiveTask = hasActiveTask
        }
    }

    private struct PendingLogRow {
        let threadID: String
        let message: String
    }

    private struct SnapshotQueryResult {
        let activeTurnCount: Int
        let recentUpdatedThreadIDs: [String]
        let recentLoggedThreadIDs: [String]
        let pendingLogRows: [PendingLogRow]
        let failedThreads: [String: CodexDesktopRuntimeSnapshot.FailedThreadState]
        let latestTurnCompletedAtByThreadID: [String: Date]
    }

    private struct SQLiteQuerySection {
        let name: String
        let sql: String
    }

    private enum LogMessageColumn: String {
        case message
        case feedbackLogBody = "feedback_log_body"
    }

    private enum LogQuerySource {
        case unavailable
        case embedded(messageColumn: LogMessageColumn)
        case attached(databaseURL: URL, messageColumn: LogMessageColumn)

        var isAvailable: Bool {
            if case .unavailable = self {
                return false
            }

            return true
        }
    }

    private let fileManager: FileManager
    private let now: () -> Date
    private let recentThreadUpdateInterval: TimeInterval
    private let recentLogInterval: TimeInterval
    private let recentActivityThreadLimit: Int
    private let activeTurnLookbackInterval: TimeInterval
    private let recentProcessActivityInterval: TimeInterval
    private let databaseLocationCacheLifetime: TimeInterval
    private let stateDatabaseURLOverride: URL?
    private let codexDirectoryURLOverride: URL?
    private let desktopLogsDirectoryURLOverride: URL?
    private let codexDirectoryURLProvider: @Sendable () -> URL
    private let sessionPendingStateCache = SessionPendingStateCache()
    private let stateDatabaseURLCache = StateDatabaseURLCache()
    private let desktopLogCandidateCache = DesktopLogCandidateCache()
    private let desktopApprovalLogCache = DesktopApprovalLogCache()

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        recentThreadUpdateInterval: TimeInterval = 60,
        recentLogInterval: TimeInterval = 60,
        recentActivityThreadLimit: Int = 256,
        activeTurnLookbackInterval: TimeInterval = 6 * 60 * 60,
        recentProcessActivityInterval: TimeInterval = 10 * 60,
        databaseLocationCacheLifetime: TimeInterval = 30,
        stateDatabaseURLOverride: URL? = nil,
        codexDirectoryURLOverride: URL? = nil,
        desktopLogsDirectoryURLOverride: URL? = nil,
        codexDirectoryURLProvider: (@Sendable () -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentThreadUpdateInterval = recentThreadUpdateInterval
        self.recentLogInterval = recentLogInterval
        self.recentActivityThreadLimit = max(1, recentActivityThreadLimit)
        self.activeTurnLookbackInterval = activeTurnLookbackInterval
        self.recentProcessActivityInterval = recentProcessActivityInterval
        self.databaseLocationCacheLifetime = max(1, databaseLocationCacheLifetime)
        self.stateDatabaseURLOverride = stateDatabaseURLOverride
        self.codexDirectoryURLOverride = codexDirectoryURLOverride
        self.desktopLogsDirectoryURLOverride = desktopLogsDirectoryURLOverride
        self.codexDirectoryURLProvider = codexDirectoryURLProvider ?? {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    func snapshot(candidates: Set<String>) throws -> CodexDesktopRuntimeSnapshot {
        try snapshot(candidateSessionPaths: Dictionary(uniqueKeysWithValues: candidates.map { ($0, nil) }))
    }

    func snapshot(candidateSessionPaths: [String: String?]) throws -> CodexDesktopRuntimeSnapshot {
        let candidates = Set(candidateSessionPaths.keys)
        let nowTimestamp = Int(now().timeIntervalSince1970)
        let threadUpdateCutoff = nowTimestamp - Int(recentThreadUpdateInterval)
        let logCutoff = nowTimestamp - Int(recentLogInterval)
        let activeTurnCutoff = nowTimestamp - Int(activeTurnLookbackInterval)
        let recentProcessCutoff = nowTimestamp - Int(recentProcessActivityInterval)
        let queryResult = try withStateDatabase { databaseURL in
            try querySnapshotState(
                candidates: candidates,
                databaseURL: databaseURL,
                threadUpdateCutoff: threadUpdateCutoff,
                logCutoff: logCutoff,
                activeTurnCutoff: activeTurnCutoff,
                recentProcessCutoff: recentProcessCutoff
            )
        }
        let activeTurnCount = queryResult.activeTurnCount
        let recentActivityThreadIDs = Set(queryResult.recentUpdatedThreadIDs + queryResult.recentLoggedThreadIDs)

        guard !candidates.isEmpty else {
            return CodexDesktopRuntimeSnapshot(
                activeTurnCount: activeTurnCount,
                runningThreadIDs: [],
                recentActivityThreadIDs: recentActivityThreadIDs,
                latestTurnCompletedAtByThreadID: queryResult.latestTurnCompletedAtByThreadID
            )
        }

        let pendingStates = queryPendingThreadStates(
            candidateSessionPaths: candidateSessionPaths,
            logPendingRows: queryResult.pendingLogRows
        )
        let failedThreads = queryResult.failedThreads
        let debugSummary = [
            "candidates=\(candidates.count)",
            "running=\(pendingStates.runningThreadIDs.count)",
            "waiting=\(pendingStates.waitingForInputThreadIDs.count)",
            "approval=\(pendingStates.approvalThreadIDs.count)",
            "failed=\(failedThreads.count)",
            "rows=\(pendingStates.debugRows.count)",
            "sample=\(pendingStates.debugRows.isEmpty ? "[]" : "[" + pendingStates.debugRows.prefix(3).joined(separator: ", ") + (pendingStates.debugRows.count > 3 ? ", +\(pendingStates.debugRows.count - 3)" : "") + "]")"
        ].joined(separator: " ")

        let databaseRunningThreadIDs: Set<String>
        if activeTurnCount > 0 {
            databaseRunningThreadIDs = Set(queryResult.recentUpdatedThreadIDs + queryResult.recentLoggedThreadIDs).intersection(candidates)
        } else {
            databaseRunningThreadIDs = []
        }
        let runningThreadIDs = databaseRunningThreadIDs.union(pendingStates.runningThreadIDs)

        return CodexDesktopRuntimeSnapshot(
            activeTurnCount: activeTurnCount,
            runningThreadIDs: runningThreadIDs,
            recentActivityThreadIDs: recentActivityThreadIDs,
            waitingForInputThreadIDs: pendingStates.waitingForInputThreadIDs,
            approvalThreadIDs: pendingStates.approvalThreadIDs,
            failedThreads: failedThreads,
            latestTurnCompletedAtByThreadID: queryResult.latestTurnCompletedAtByThreadID,
            debugSummary: debugSummary
        )
    }

    func sessionFallbackSnapshot(
        candidateSessionPaths: [String: String?],
        databaseError: String? = nil
    ) -> CodexDesktopRuntimeSnapshot? {
        guard candidateSessionPaths.values.contains(where: { $0 != nil }) else {
            return nil
        }

        let sessionStates = querySessionPendingThreadStates(candidateSessionPaths: candidateSessionPaths)
        let desktopApprovalStates = queryDesktopPendingApprovalThreadStates(
            candidateThreadIDs: Set(candidateSessionPaths.keys)
        )
        let approvalThreadIDs = sessionStates.approvalThreadIDs.union(desktopApprovalStates.approvalThreadIDs)
        let runningThreadIDs = sessionStates.activeTaskThreadIDs
            .subtracting(sessionStates.waitingForInputThreadIDs)
            .subtracting(approvalThreadIDs)
        let debugSummary = [
            "source=session-fallback",
            "candidates=\(candidateSessionPaths.count)",
            "running=\(runningThreadIDs.count)",
            "waiting=\(sessionStates.waitingForInputThreadIDs.count)",
            "approval=\(approvalThreadIDs.count)",
            "rows=\(sessionStates.debugRows.count + desktopApprovalStates.debugRows.count)",
            "sample=\(desktopApprovalDebugSample(sessionDebugRows: sessionStates.debugRows, desktopDebugRows: desktopApprovalStates.debugRows))",
            "databaseError=\(databaseError ?? "-")",
        ].joined(separator: " ")

        return CodexDesktopRuntimeSnapshot(
            activeTurnCount: sessionStates.activeTaskThreadIDs.isEmpty ? 0 : 1,
            runningThreadIDs: runningThreadIDs,
            recentActivityThreadIDs: [],
            waitingForInputThreadIDs: sessionStates.waitingForInputThreadIDs,
            approvalThreadIDs: approvalThreadIDs,
            failedThreads: [:],
            debugSummary: debugSummary
        )
    }

    func threads(threadIDs: Set<String>) throws -> [CodexThread] {
        guard !threadIDs.isEmpty else {
            return []
        }

        let candidateList = threadIDs
            .map(sqlQuoted)
            .sorted()
            .joined(separator: ", ")
        let output = try withStateDatabase { databaseURL in
            try runSQLite(
                sql: """
                SELECT json_object(
                    'id', id,
                    'preview', CASE
                        WHEN TRIM(first_user_message) != '' THEN first_user_message
                        ELSE title
                    END,
                    'createdAt', created_at,
                    'updatedAt', updated_at,
                    'cwd', cwd,
                    'name', title,
                    'path', rollout_path,
                    'source', source,
                    'agentRole', agent_role,
                    'agentNickname', agent_nickname
                )
                FROM threads
                WHERE archived = 0
                  AND id IN (\(candidateList))
                ORDER BY updated_at DESC;
                """,
                databaseURL: databaseURL
            )
        }
        var threads: [CodexThread] = []

        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let preview = object["preview"] as? String,
                  let createdAt = object["createdAt"] as? Int ?? (object["createdAt"] as? NSNumber)?.intValue,
                  let updatedAt = object["updatedAt"] as? Int ?? (object["updatedAt"] as? NSNumber)?.intValue,
                  let cwd = object["cwd"] as? String
            else {
                continue
            }

            threads.append(
                CodexThread(
                    id: id,
                    preview: preview,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    status: .notLoaded,
                    cwd: cwd,
                    name: object["name"] as? String,
                    path: object["path"] as? String,
                    source: object["source"] as? String,
                    agentRole: object["agentRole"] as? String,
                    agentNickname: object["agentNickname"] as? String
                )
            )
        }

        return threads
    }

    func recentThreads(limit: Int) throws -> [CodexThread] {
        guard limit > 0 else {
            return []
        }

        let output = try withStateDatabase { databaseURL in
            try runSQLite(
                sql: """
                SELECT id
                FROM threads
                WHERE archived = 0
                ORDER BY updated_at DESC
                LIMIT \(limit);
                """,
                databaseURL: databaseURL
            )
        }
        let recentThreadIDs = parseSQLiteLines(output.split(separator: "\n").map(String.init))
        guard !recentThreadIDs.isEmpty else {
            return []
        }

        let threadsByID = Dictionary(
            uniqueKeysWithValues: try threads(threadIDs: Set(recentThreadIDs)).map { ($0.id, $0) }
        )

        return recentThreadIDs.compactMap { threadsByID[$0] }
    }

    private func withStateDatabase<Result>(_ operation: (URL) throws -> Result) throws -> Result {
        if let stateDatabaseURLOverride {
            return try operation(stateDatabaseURLOverride)
        }

        let referenceNow = now()
        let codexDirectoryURL = resolvedCodexDirectoryURL()
        var lastRetriableError: ReaderError?

        if let cachedURL = stateDatabaseURLCache.value(
            now: referenceNow,
            codexDirectoryURL: codexDirectoryURL,
            fileManager: fileManager,
            cacheLifetime: databaseLocationCacheLifetime
        ) {
            do {
                return try operation(cachedURL)
            } catch let error as ReaderError where error.isRetriableDatabaseOpenFailure {
                lastRetriableError = error
                stateDatabaseURLCache.clear()
            }
        }

        var candidateURLs: [URL] = []
        for url in try locateStateDatabaseCandidates() where !candidateURLs.contains(url) {
            candidateURLs.append(url)
        }

        guard !candidateURLs.isEmpty else {
            throw ReaderError.databaseNotFound
        }

        for candidateURL in candidateURLs {
            do {
                let result = try operation(candidateURL)
                stateDatabaseURLCache.store(candidateURL, codexDirectoryURL: codexDirectoryURL, checkedAt: referenceNow)
                return result
            } catch let error as ReaderError where error.isRetriableDatabaseOpenFailure {
                lastRetriableError = error
                stateDatabaseURLCache.clear()
                continue
            }
        }

        if let lastRetriableError {
            throw lastRetriableError
        }

        throw ReaderError.databaseNotFound
    }

    private func locateStateDatabase() throws -> URL {
        try withStateDatabase { $0 }
    }

    private func locateStateDatabaseCandidates() throws -> [URL] {
        if let stateDatabaseURLOverride {
            return [stateDatabaseURLOverride]
        }

        let codexDirectory = resolvedCodexDirectoryURL()
        let candidateURLs = try fileManager.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("state_") && url.pathExtension == "sqlite"
        }

        let sortedCandidateURLs = candidateURLs.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }

        guard !sortedCandidateURLs.isEmpty else {
            throw ReaderError.databaseNotFound
        }

        return sortedCandidateURLs
    }

    private func resolvedCodexDirectoryURL() -> URL {
        (codexDirectoryURLOverride ?? codexDirectoryURLProvider()).standardizedFileURL
    }

    private func querySnapshotState(
        candidates: Set<String>,
        databaseURL: URL,
        threadUpdateCutoff: Int,
        logCutoff: Int,
        activeTurnCutoff: Int,
        recentProcessCutoff: Int
    ) throws -> SnapshotQueryResult {
        let logQuerySource = resolveLogQuerySource(stateDatabaseURL: databaseURL)
        let logsViewName = "codex_logs"
        var sections = [
            SQLiteQuerySection(
                name: "activeTurnCount",
                sql: logQuerySource.isAvailable
                    ? """
                    WITH per_process AS (
                        SELECT
                            process_uuid,
                            MAX(ts) AS last_ts,
                            COALESCE(SUM(CASE WHEN message = 'app-server event: turn/started' THEN 1 ELSE 0 END), 0) AS started_count,
                            COALESCE(SUM(CASE WHEN message = 'app-server event: turn/completed' THEN 1 ELSE 0 END), 0) AS completed_count
                        FROM \(logsViewName)
                        WHERE target = 'codex_app_server::outgoing_message'
                          AND ts >= \(activeTurnCutoff)
                        GROUP BY process_uuid
                    )
                    SELECT MAX(0, COALESCE(MAX(started_count - completed_count), 0))
                    FROM per_process
                    WHERE last_ts >= \(recentProcessCutoff);
                    """
                    : "SELECT 0;"
            ),
            SQLiteQuerySection(
                name: "recentUpdates",
                sql: """
                SELECT id
                FROM threads
                WHERE archived = 0
                  AND updated_at >= \(threadUpdateCutoff)
                ORDER BY updated_at DESC
                LIMIT \(recentActivityThreadLimit);
                """
            )
        ]

        if logQuerySource.isAvailable {
            sections.append(
                SQLiteQuerySection(
                    name: "recentLogs",
                    sql: """
                    SELECT thread_id
                    FROM \(logsViewName)
                    WHERE thread_id IS NOT NULL
                      AND ts >= \(logCutoff)
                    GROUP BY thread_id;
                    """
                )
            )
        }

        if !candidates.isEmpty, logQuerySource.isAvailable {
            let candidateList = candidates
                .map(sqlQuoted)
                .sorted()
                .joined(separator: ", ")
            sections.append(
                SQLiteQuerySection(
                    name: "pendingLogs",
                    sql: """
                    WITH ranked AS (
                        SELECT
                            thread_id,
                            REPLACE(REPLACE(message, char(10), ' '), char(13), ' ') AS message,
                            ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY ts DESC, ts_nanos DESC, id DESC) AS row_number
                        FROM \(logsViewName)
                        WHERE thread_id IN (\(candidateList))
                          AND target = 'codex_core::stream_events_utils'
                          AND (
                            message = 'Output item'
                            OR message LIKE 'ToolCall:%'
                          )
                    )
                    SELECT json_object('thread_id', thread_id, 'message', message)
                    FROM ranked
                    WHERE row_number = 1;
                    """
                )
            )
            sections.append(
                SQLiteQuerySection(
                    name: "failedThreads",
                    sql: """
                    WITH ranked AS (
                        SELECT
                            thread_id,
                            message,
                            ts,
                            ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY ts DESC, ts_nanos DESC, id DESC) AS row_number
                        FROM \(logsViewName)
                        WHERE thread_id IN (\(candidateList))
                          AND target = 'codex_core::codex'
                          AND message LIKE 'Turn error:%'
                    )
                    SELECT json_object('thread_id', thread_id, 'message', message, 'ts', ts)
                    FROM ranked
                    WHERE row_number = 1;
                    """
                )
            )
            sections.append(
                SQLiteQuerySection(
                    name: "latestTurnCompleted",
                    sql: """
                    WITH ranked AS (
                        SELECT
                            thread_id,
                            ts,
                            ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY ts DESC, ts_nanos DESC, id DESC) AS row_number
                        FROM \(logsViewName)
                        WHERE thread_id IN (\(candidateList))
                          AND target = 'codex_app_server::outgoing_message'
                          AND message = 'app-server event: turn/completed'
                    )
                    SELECT json_object('thread_id', thread_id, 'ts', ts)
                    FROM ranked
                    WHERE row_number = 1;
                    """
                )
            )
        }

        let sectionedOutput = try runSQLiteSections(
            sections,
            databaseURL: databaseURL,
            preludeSQL: logsBootstrapSQL(for: logQuerySource, viewName: logsViewName)
        )
        let activeTurnCount = Int(sectionedOutput["activeTurnCount"]?.first ?? "") ?? 0
        let recentUpdatedThreadIDs = parseSQLiteLines(sectionedOutput["recentUpdates"] ?? [])
        let recentLoggedThreadIDs = parseSQLiteLines(sectionedOutput["recentLogs"] ?? [])
        let pendingLogRows = parsePendingLogRows(sectionedOutput["pendingLogs"] ?? [])
        let failedThreads = parseFailedThreads(sectionedOutput["failedThreads"] ?? [])
        let latestTurnCompletedAtByThreadID = parseLatestTurnCompleted(sectionedOutput["latestTurnCompleted"] ?? [])

        return SnapshotQueryResult(
            activeTurnCount: activeTurnCount,
            recentUpdatedThreadIDs: recentUpdatedThreadIDs,
            recentLoggedThreadIDs: recentLoggedThreadIDs,
            pendingLogRows: pendingLogRows,
            failedThreads: failedThreads,
            latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
        )
    }

    private func resolveLogQuerySource(stateDatabaseURL: URL) -> LogQuerySource {
        if let messageColumn = logMessageColumn(in: stateDatabaseURL) {
            return .embedded(messageColumn: messageColumn)
        }

        guard let logsDatabaseURL = locateLogsDatabaseCandidate(near: stateDatabaseURL),
              let messageColumn = logMessageColumn(in: logsDatabaseURL)
        else {
            return .unavailable
        }

        return .attached(databaseURL: logsDatabaseURL, messageColumn: messageColumn)
    }

    private func locateLogsDatabaseCandidate(near stateDatabaseURL: URL) -> URL? {
        let directoryURL = stateDatabaseURL.deletingLastPathComponent()
        guard let candidateURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let logDatabaseURLs = candidateURLs
            .filter { url in
                url.lastPathComponent.hasPrefix("logs_") && url.pathExtension == "sqlite"
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }

        return logDatabaseURLs.first
    }

    private func logMessageColumn(in databaseURL: URL) -> LogMessageColumn? {
        guard let tableOutput = try? runSQLite(
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name = 'logs';
            """,
            databaseURL: databaseURL
        ) else {
            return nil
        }

        let tableNames = parseSQLiteLines(tableOutput.split(separator: "\n").map(String.init))
        guard tableNames.contains("logs"),
              let pragmaOutput = try? runSQLite(sql: "PRAGMA table_info(logs);", databaseURL: databaseURL)
        else {
            return nil
        }

        let columnNames = Set<String>(
            parseSQLiteLines(pragmaOutput.split(separator: "\n").map(String.init))
                .compactMap { line in
                    let columns = line.split(separator: "|", omittingEmptySubsequences: false)
                    guard columns.count > 1 else {
                        return nil
                    }

                    return String(columns[1])
                }
        )

        if columnNames.contains(LogMessageColumn.message.rawValue) {
            return .message
        }

        if columnNames.contains(LogMessageColumn.feedbackLogBody.rawValue) {
            return .feedbackLogBody
        }

        return nil
    }

    private func logsBootstrapSQL(for source: LogQuerySource, viewName: String) -> String? {
        switch source {
        case .unavailable:
            return nil
        case let .embedded(messageColumn):
            return """
            CREATE TEMP VIEW \(viewName) AS
            SELECT
                id,
                ts,
                ts_nanos,
                target,
                \(messageColumn.rawValue) AS message,
                thread_id,
                process_uuid
            FROM logs;
            """
        case let .attached(databaseURL, messageColumn):
            return """
            ATTACH DATABASE \(sqlQuoted(Self.sqliteDatabaseArgument(for: databaseURL))) AS logsdb;
            CREATE TEMP VIEW \(viewName) AS
            SELECT
                id,
                ts,
                ts_nanos,
                target,
                \(messageColumn.rawValue) AS message,
                thread_id,
                process_uuid
            FROM logsdb.logs;
            """
        }
    }

    private func parseSQLiteLines(_ lines: [String]) -> [String] {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parsePendingLogRows(_ lines: [String]) -> [PendingLogRow] {
        lines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadID = object["thread_id"] as? String,
                  let message = object["message"] as? String
            else {
                return nil
            }

            return PendingLogRow(threadID: threadID, message: message)
        }
    }

    private func parseFailedThreads(_ lines: [String]) -> [String: CodexDesktopRuntimeSnapshot.FailedThreadState] {
        var failedThreads: [String: CodexDesktopRuntimeSnapshot.FailedThreadState] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadID = object["thread_id"] as? String,
                  let message = object["message"] as? String,
                  let timestamp = object["ts"] as? Double ?? (object["ts"] as? NSNumber)?.doubleValue
            else {
                continue
            }

            failedThreads[threadID] = CodexDesktopRuntimeSnapshot.FailedThreadState(
                message: message,
                loggedAt: Date(timeIntervalSince1970: timestamp)
            )
        }

        return failedThreads
    }

    private func parseLatestTurnCompleted(_ lines: [String]) -> [String: Date] {
        var latestTurnCompletedAtByThreadID: [String: Date] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadID = object["thread_id"] as? String,
                  let timestamp = object["ts"] as? Double ?? (object["ts"] as? NSNumber)?.doubleValue
            else {
                continue
            }

            latestTurnCompletedAtByThreadID[threadID] = Date(timeIntervalSince1970: timestamp)
        }

        return latestTurnCompletedAtByThreadID
    }

    private func queryPendingThreadStates(
        candidateSessionPaths: [String: String?],
        logPendingRows: [PendingLogRow]
    ) -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, runningThreadIDs: Set<String>, debugRows: [String]) {
        let logStates = queryLogPendingThreadStates(logPendingRows: logPendingRows)
        let sessionStates = querySessionPendingThreadStates(candidateSessionPaths: candidateSessionPaths)
        let desktopApprovalStates = queryDesktopPendingApprovalThreadStates(
            candidateThreadIDs: Set(candidateSessionPaths.keys)
        )
        let waitingForInputThreadIDs = logStates.waitingForInputThreadIDs.union(sessionStates.waitingForInputThreadIDs)
        let approvalThreadIDs = logStates.approvalThreadIDs
            .union(sessionStates.approvalThreadIDs)
            .union(desktopApprovalStates.approvalThreadIDs)
        let runningThreadIDs = sessionStates.activeTaskThreadIDs
            .subtracting(waitingForInputThreadIDs)
            .subtracting(approvalThreadIDs)

        return (
            waitingForInputThreadIDs: waitingForInputThreadIDs,
            approvalThreadIDs: approvalThreadIDs,
            runningThreadIDs: runningThreadIDs,
            debugRows: logStates.debugRows + sessionStates.debugRows + desktopApprovalStates.debugRows
        )
    }

    private func queryDesktopPendingApprovalThreadStates(
        candidateThreadIDs: Set<String>
    ) -> (approvalThreadIDs: Set<String>, debugRows: [String]) {
        guard !candidateThreadIDs.isEmpty else {
            return ([], [])
        }

        let logURLs = locateDesktopLogCandidates()
        guard !logURLs.isEmpty else {
            return ([], [])
        }
        desktopApprovalLogCache.prune(keepingPaths: Set(logURLs.map(\.path)))

        var approvalThreadIDs: Set<String> = []

        for logURL in logURLs {
            approvalThreadIDs.formUnion(
                desktopPendingApprovalThreadIDs(for: logURL).intersection(candidateThreadIDs)
            )
        }

        let debugRows = approvalThreadIDs.sorted().map { threadID in
            "\(String(threadID.prefix(8))):desktop-approval"
        }
        return (approvalThreadIDs, debugRows)
    }

    private func locateDesktopLogCandidates(maxDays: Int = 2, limit: Int = 4) -> [URL] {
        let logsRootURL = resolvedDesktopLogsDirectoryURL()
        guard fileManager.fileExists(atPath: logsRootURL.path) else {
            return []
        }

        let calendar = Calendar.current
        let currentDate = now()
        let cacheKey = desktopLogCandidateCacheKey(
            logsRootURL: logsRootURL,
            now: currentDate,
            maxDays: maxDays,
            limit: limit
        )
        if let cachedLogURLs = desktopLogCandidateCache.value(
            key: cacheKey,
            now: currentDate,
            cacheLifetime: DesktopLogCachePolicy.candidateCacheLifetime
        ) {
            return cachedLogURLs
        }

        var candidates: [URL] = []

        for dayOffset in 0..<maxDays {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: currentDate) else {
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day
            else {
                continue
            }

            let directoryURL = logsRootURL
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)

            guard let logURLs = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            candidates.append(contentsOf:
                contentsSortedByModificationDateDescending(logURLs)
                    .filter { $0.pathExtension == "log" }
            )
        }

        let sortedCandidates = Array(contentsSortedByModificationDateDescending(candidates).prefix(limit))
        desktopLogCandidateCache.store(sortedCandidates, key: cacheKey, checkedAt: currentDate)
        return sortedCandidates
    }

    private func desktopLogCandidateCacheKey(
        logsRootURL: URL,
        now: Date,
        maxDays: Int,
        limit: Int
    ) -> String {
        let calendar = Calendar.current
        let dayTokens = (0..<maxDays).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: -dayOffset, to: now)
        }.map { day in
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            let year = components.year ?? 0
            let month = components.month ?? 0
            let day = components.day ?? 0
            return String(format: "%04d-%02d-%02d", year, month, day)
        }

        return logsRootURL.path + "|" + dayTokens.joined(separator: "|") + "|limit=\(limit)"
    }

    private func contentsSortedByModificationDateDescending(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let lhsValues = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? URLResourceValues()
            let rhsValues = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? URLResourceValues()
            let lhsIsRegular = lhsValues.isRegularFile ?? true
            let rhsIsRegular = rhsValues.isRegularFile ?? true

            if lhsIsRegular != rhsIsRegular {
                return lhsIsRegular && !rhsIsRegular
            }

            let lhsDate = lhsValues.contentModificationDate ?? .distantPast
            let rhsDate = rhsValues.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    private func recentDesktopLogContents(at logURL: URL, maximumBytes: Int = 256 * 1024) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return try? String(contentsOf: logURL, encoding: .utf8)
        }

        let totalBytes = fileSize.intValue
        guard totalBytes > maximumBytes else {
            return try? String(contentsOf: logURL, encoding: .utf8)
        }

        guard let handle = try? FileHandle(forReadingFrom: logURL) else {
            return nil
        }

        defer { try? handle.close() }

        let offset = UInt64(max(0, totalBytes - maximumBytes))
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard var contents = String(data: data, encoding: .utf8) else {
                return nil
            }

            if offset > 0, let newlineIndex = contents.firstIndex(of: "\n") {
                contents = String(contents[contents.index(after: newlineIndex)...])
            }

            return contents
        } catch {
            return nil
        }
    }

    private func resolvedDesktopLogsDirectoryURL() -> URL {
        (desktopLogsDirectoryURLOverride
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("com.openai.codex", isDirectory: true)
        ).standardizedFileURL
    }

    private func desktopApprovalDebugSample(sessionDebugRows: [String], desktopDebugRows: [String]) -> String {
        let debugRows = sessionDebugRows + desktopDebugRows
        guard !debugRows.isEmpty else {
            return "[]"
        }

        let sample = debugRows.prefix(3).joined(separator: ", ")
        if debugRows.count > 3 {
            return "[\(sample), +\(debugRows.count - 3)]"
        }

        return "[\(sample)]"
    }

    private func desktopPendingApprovalThreadIDs(for logURL: URL) -> Set<String> {
        let resourceValues = (try? logURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) ?? URLResourceValues()
        let modificationDate = resourceValues.contentModificationDate
        let fileSize = resourceValues.fileSize

        if let cachedThreadIDs = desktopApprovalLogCache.value(
            for: logURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        ) {
            return cachedThreadIDs
        }

        guard let contents = recentDesktopLogContents(at: logURL) else {
            return []
        }

        let approvalThreadIDs = Self.parseDesktopPendingApprovalThreadIDs(from: contents)
        desktopApprovalLogCache.store(
            approvalThreadIDs,
            for: logURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        )
        return approvalThreadIDs
    }

    static func parseDesktopPendingApprovalThreadStates(
        from contents: String,
        candidateThreadIDs: Set<String>
    ) -> (approvalThreadIDs: Set<String>, debugRows: [String]) {
        let approvalThreadIDs = parseDesktopPendingApprovalThreadIDs(from: contents)
            .intersection(candidateThreadIDs)
        let debugRows = approvalThreadIDs.sorted().map { threadID in
            "\(String(threadID.prefix(8))):desktop-approval"
        }

        return (approvalThreadIDs, debugRows)
    }

    static func parseDesktopPendingApprovalThreadIDs(from contents: String) -> Set<String> {
        var requestIDToThreadID: [String: String] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)

            if line.contains("[desktop-notifications] show approval"),
               let conversationID = tokenValue(in: line, after: "conversationId="),
               tokenValue(in: line, after: "kind=") == "commandExecution",
               let requestID = tokenValue(in: line, after: "requestId=") {
                requestIDToThreadID[requestID] = conversationID
                continue
            }

            if line.contains("method=item/commandExecution/requestApproval"),
               let requestID = tokenValue(in: line, after: "id=") {
                requestIDToThreadID.removeValue(forKey: requestID)
            }
        }

        return Set(requestIDToThreadID.values)
    }

    private static func tokenValue(in line: String, after marker: String) -> String? {
        guard let markerRange = line.range(of: marker) else {
            return nil
        }

        let suffix = line[markerRange.upperBound...]
        let token = suffix.prefix { !$0.isWhitespace }
        guard !token.isEmpty else {
            return nil
        }

        return String(token)
    }

    private func queryLogPendingThreadStates(logPendingRows: [PendingLogRow]) -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, debugRows: [String]) {
        var waitingThreadIDs: Set<String> = []
        var approvalThreadIDs: Set<String> = []
        var debugRows: [String] = []

        for row in logPendingRows {
            let threadID = row.threadID
            let message = row.message
            let shortID = String(threadID.prefix(8))

            if message.hasPrefix("ToolCall: request_user_input ") {
                waitingThreadIDs.insert(threadID)
                debugRows.append("\(shortID):wait:\(message.prefix(36))")
                continue
            }

            let lowercasedMessage = message.lowercased()
            if message.hasPrefix("ToolCall:"),
               lowercasedMessage.contains("requestapproval") || lowercasedMessage.contains("request_approval") || lowercasedMessage.contains("request approval") {
                approvalThreadIDs.insert(threadID)
                debugRows.append("\(shortID):approval:\(message.prefix(36))")
                continue
            }

            debugRows.append("\(shortID):other:\(message.prefix(24))")
        }

        return (waitingThreadIDs, approvalThreadIDs, debugRows)
    }

    private func querySessionPendingThreadStates(
        candidateSessionPaths: [String: String?]
    ) -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, activeTaskThreadIDs: Set<String>, debugRows: [String]) {
        sessionPendingStateCache.prune(keepingPaths: Set(candidateSessionPaths.values.compactMap { $0 }))

        var waitingThreadIDs: Set<String> = []
        var approvalThreadIDs: Set<String> = []
        var activeTaskThreadIDs: Set<String> = []
        var debugRows: [String] = []

        for (threadID, rawPath) in candidateSessionPaths.sorted(by: { $0.key < $1.key }) {
            guard let rawPath,
                  let state = sessionPendingState(forSessionFileAt: URL(fileURLWithPath: rawPath))
            else {
                continue
            }

            let shortID = String(threadID.prefix(8))

            if state.waitingForInput {
                waitingThreadIDs.insert(threadID)
                debugRows.append("\(shortID):session-wait")
            }

            if state.needsApproval {
                approvalThreadIDs.insert(threadID)
                debugRows.append("\(shortID):session-approval")
            }

            if state.hasActiveTask {
                activeTaskThreadIDs.insert(threadID)
                debugRows.append("\(shortID):session-active")
            }
        }

        return (waitingThreadIDs, approvalThreadIDs, activeTaskThreadIDs, debugRows)
    }

    func sessionPendingState(forSessionFileAt sessionURL: URL) -> SessionPendingState? {
        let resourceValues = (try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) ?? URLResourceValues()
        let modificationDate = resourceValues.contentModificationDate
        let fileSize = resourceValues.fileSize

        if let cached = sessionPendingStateCache.value(for: sessionURL.path, modificationDate: modificationDate, fileSize: fileSize) {
            return cached
        }

        guard let contents = try? String(contentsOf: sessionURL, encoding: .utf8) else {
            return nil
        }

        let state = Self.parseSessionPendingState(from: contents)
        sessionPendingStateCache.store(state, for: sessionURL.path, modificationDate: modificationDate, fileSize: fileSize)
        return state
    }

    static func parseSessionPendingState(from contents: String) -> SessionPendingState {
        var unresolvedRequestUserInputCallIDs: Set<String> = []
        var unresolvedApprovalCallIDs: Set<String> = []
        var activeTaskIDs: Set<String> = []

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else {
                continue
            }

            switch type {
            case "event_msg":
                if payloadType == "task_started" {
                    guard let turnID = payload["turn_id"] as? String else {
                        continue
                    }

                    // A thread only executes one turn at a time; a newer task start
                    // supersedes any orphaned active turn that never emitted completion.
                    activeTaskIDs = [turnID]
                    unresolvedRequestUserInputCallIDs.removeAll()
                    unresolvedApprovalCallIDs.removeAll()
                } else if payloadType == "task_complete" || payloadType == "turn_aborted" {
                    guard let turnID = payload["turn_id"] as? String else {
                        continue
                    }

                    activeTaskIDs.remove(turnID)
                    unresolvedRequestUserInputCallIDs.removeAll()
                    unresolvedApprovalCallIDs.removeAll()
                } else if payloadType == "exec_approval_request" {
                    guard let callID = payload["call_id"] as? String else {
                        continue
                    }

                    unresolvedApprovalCallIDs.insert(callID)
                } else if payloadType == "exec_command_begin" || payloadType == "exec_command_end" {
                    guard let callID = payload["call_id"] as? String else {
                        continue
                    }

                    unresolvedApprovalCallIDs.remove(callID)
                }
            case "response_item":
                switch payloadType {
                case "function_call":
                    guard let name = payload["name"] as? String,
                          let callID = payload["call_id"] as? String
                    else {
                        continue
                    }

                    if name == "request_user_input" {
                        unresolvedRequestUserInputCallIDs.insert(callID)
                    } else if name == "request_approval" || name == "requestApproval" {
                        unresolvedApprovalCallIDs.insert(callID)
                    } else if isEscalatedExecCommandCall(name: name, arguments: payload["arguments"]) {
                        unresolvedApprovalCallIDs.insert(callID)
                    }
                case "function_call_output":
                    guard let callID = payload["call_id"] as? String else {
                        continue
                    }

                    unresolvedRequestUserInputCallIDs.remove(callID)
                    unresolvedApprovalCallIDs.remove(callID)
                default:
                    continue
                }
            default:
                continue
            }
        }

        return SessionPendingState(
            waitingForInput: !unresolvedRequestUserInputCallIDs.isEmpty,
            needsApproval: !unresolvedApprovalCallIDs.isEmpty,
            hasActiveTask: !activeTaskIDs.isEmpty
        )
    }

    private static func isEscalatedExecCommandCall(name: String, arguments: Any?) -> Bool {
        guard name == "exec_command",
              let object = jsonObject(from: arguments)
        else {
            return false
        }

        let sandboxPermissions = object["sandbox_permissions"] as? String
            ?? object["sandboxPermissions"] as? String
        return sandboxPermissions == "require_escalated"
    }

    private static func jsonObject(from value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] {
            return object
        }

        guard let rawJSON = value as? String,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return object
    }

    private func sqlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func runSQLiteSections(
        _ sections: [SQLiteQuerySection],
        databaseURL: URL,
        preludeSQL: String? = nil
    ) throws -> [String: [String]] {
        let markerPrefix = "__codextension_section__:"
        let sectionSQL = sections
            .map { section in
                """
                SELECT '\(markerPrefix)\(section.name)';
                \(section.sql)
                """
            }
            .joined(separator: "\n")
        let combinedSQL = [preludeSQL, sectionSQL]
            .compactMap { value in
                guard let value else {
                    return nil
                }

                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")

        let output = try runSQLite(sql: combinedSQL, databaseURL: databaseURL)
        var linesBySection: [String: [String]] = [:]
        var currentSectionName: String?

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(markerPrefix) {
                currentSectionName = String(line.dropFirst(markerPrefix.count))
                if let currentSectionName {
                    linesBySection[currentSectionName] = []
                }
                continue
            }

            guard let currentSectionName, !line.isEmpty else {
                continue
            }

            linesBySection[currentSectionName, default: []].append(line)
        }

        return linesBySection
    }

    private func runSQLite(sql: String, databaseURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-noheader",
            "-cmd",
            ".timeout 1000",
            Self.sqliteDatabaseArgument(for: databaseURL),
            sql,
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderError.queryFailed(
                message: message ?? "sqlite3 exited with status \(process.terminationStatus)",
                databasePath: databaseURL.path
            )
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }

    static func sqliteDatabaseArgument(for databaseURL: URL) -> String {
        var components = URLComponents(url: databaseURL.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "mode", value: "ro"),
        ]

        return components?.string ?? databaseURL.path
    }
}

final class SessionPendingStateCache {
    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int?
        let state: CodexDesktopStateReader.SessionPendingState
    }

    private var entries: [String: Entry] = [:]

    func value(for path: String, modificationDate: Date?, fileSize: Int?) -> CodexDesktopStateReader.SessionPendingState? {
        guard let entry = entries[path],
              entry.modificationDate == modificationDate,
              entry.fileSize == fileSize
        else {
            return nil
        }

        return entry.state
    }

    func store(_ state: CodexDesktopStateReader.SessionPendingState, for path: String, modificationDate: Date?, fileSize: Int?) {
        entries[path] = Entry(modificationDate: modificationDate, fileSize: fileSize, state: state)
    }

    func prune(keepingPaths: Set<String>) {
        entries = entries.filter { keepingPaths.contains($0.key) }
    }
}

private final class StateDatabaseURLCache {
    private struct Entry {
        let codexDirectoryURL: URL
        let url: URL
        let checkedAt: Date
    }

    private var entry: Entry?

    func value(
        now: Date,
        codexDirectoryURL: URL,
        fileManager: FileManager,
        cacheLifetime: TimeInterval
    ) -> URL? {
        guard let entry,
              entry.codexDirectoryURL == codexDirectoryURL,
              now.timeIntervalSince(entry.checkedAt) < cacheLifetime,
              fileManager.fileExists(atPath: entry.url.path)
        else {
            return nil
        }

        return entry.url
    }

    func store(_ url: URL, codexDirectoryURL: URL, checkedAt: Date) {
        entry = Entry(codexDirectoryURL: codexDirectoryURL, url: url, checkedAt: checkedAt)
    }

    func clear() {
        entry = nil
    }
}

private enum DesktopLogCachePolicy {
    static let candidateCacheLifetime: TimeInterval = 5
}

private final class DesktopLogCandidateCache {
    private struct Entry {
        let key: String
        let checkedAt: Date
        let urls: [URL]
    }

    private var entry: Entry?

    func value(key: String, now: Date, cacheLifetime: TimeInterval) -> [URL]? {
        guard let entry,
              entry.key == key,
              now.timeIntervalSince(entry.checkedAt) < cacheLifetime
        else {
            return nil
        }

        return entry.urls
    }

    func store(_ urls: [URL], key: String, checkedAt: Date) {
        entry = Entry(key: key, checkedAt: checkedAt, urls: urls)
    }
}

private final class DesktopApprovalLogCache {
    private struct Entry {
        let modificationDate: Date?
        let fileSize: Int?
        let approvalThreadIDs: Set<String>
    }

    private var entries: [String: Entry] = [:]

    func value(for path: String, modificationDate: Date?, fileSize: Int?) -> Set<String>? {
        guard let entry = entries[path],
              entry.modificationDate == modificationDate,
              entry.fileSize == fileSize
        else {
            return nil
        }

        return entry.approvalThreadIDs
    }

    func store(_ approvalThreadIDs: Set<String>, for path: String, modificationDate: Date?, fileSize: Int?) {
        entries[path] = Entry(
            modificationDate: modificationDate,
            fileSize: fileSize,
            approvalThreadIDs: approvalThreadIDs
        )
    }

    func prune(keepingPaths: Set<String>) {
        entries = entries.filter { keepingPaths.contains($0.key) }
    }
}

extension CodexDesktopStateReader {
    enum ReaderError: LocalizedError {
        case databaseNotFound
        case queryFailed(message: String, databasePath: String?)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "Could not find a Codex state database in the configured Codex home."
            case let .queryFailed(message, _):
                return message
            }
        }

        var isRetriableDatabaseOpenFailure: Bool {
            switch self {
            case .databaseNotFound:
                return false
            case let .queryFailed(message, _):
                let lowercaseMessage = message.lowercased()
                return lowercaseMessage.contains("unable to open database file")
                    || lowercaseMessage.contains("database is locked")
                    || lowercaseMessage.contains("database table is locked")
                    || lowercaseMessage.contains("database schema is locked")
            }
        }

        var databasePath: String? {
            switch self {
            case .databaseNotFound:
                return nil
            case let .queryFailed(_, databasePath):
                return databasePath
            }
        }
    }
}
