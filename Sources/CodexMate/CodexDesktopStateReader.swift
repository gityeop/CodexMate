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
    let debugSummary: String

    init(
        activeTurnCount: Int,
        runningThreadIDs: Set<String>,
        recentActivityThreadIDs: Set<String> = [],
        waitingForInputThreadIDs: Set<String> = [],
        approvalThreadIDs: Set<String> = [],
        failedThreads: [String: FailedThreadState] = [:],
        debugSummary: String = ""
    ) {
        self.activeTurnCount = activeTurnCount
        self.runningThreadIDs = runningThreadIDs
        self.recentActivityThreadIDs = recentActivityThreadIDs
        self.waitingForInputThreadIDs = waitingForInputThreadIDs
        self.approvalThreadIDs = approvalThreadIDs
        self.failedThreads = failedThreads
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
    }

    private struct SQLiteQuerySection {
        let name: String
        let sql: String
    }

    private let fileManager: FileManager
    private let now: () -> Date
    private let recentThreadUpdateInterval: TimeInterval
    private let recentLogInterval: TimeInterval
    private let activeTurnLookbackInterval: TimeInterval
    private let recentProcessActivityInterval: TimeInterval
    private let databaseLocationCacheLifetime: TimeInterval
    private let stateDatabaseURLOverride: URL?
    private let codexDirectoryURLOverride: URL?
    private let sessionPendingStateCache = SessionPendingStateCache()
    private let stateDatabaseURLCache = StateDatabaseURLCache()

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        recentThreadUpdateInterval: TimeInterval = 10,
        recentLogInterval: TimeInterval = 15,
        activeTurnLookbackInterval: TimeInterval = 6 * 60 * 60,
        recentProcessActivityInterval: TimeInterval = 10 * 60,
        databaseLocationCacheLifetime: TimeInterval = 30,
        stateDatabaseURLOverride: URL? = nil,
        codexDirectoryURLOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentThreadUpdateInterval = recentThreadUpdateInterval
        self.recentLogInterval = recentLogInterval
        self.activeTurnLookbackInterval = activeTurnLookbackInterval
        self.recentProcessActivityInterval = recentProcessActivityInterval
        self.databaseLocationCacheLifetime = max(1, databaseLocationCacheLifetime)
        self.stateDatabaseURLOverride = stateDatabaseURLOverride
        self.codexDirectoryURLOverride = codexDirectoryURLOverride
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
                recentActivityThreadIDs: recentActivityThreadIDs
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

    private func withStateDatabase<Result>(_ operation: (URL) throws -> Result) throws -> Result {
        if let stateDatabaseURLOverride {
            return try operation(stateDatabaseURLOverride)
        }

        let referenceNow = now()
        var candidateURLs: [URL] = []

        if let cachedURL = stateDatabaseURLCache.value(
            now: referenceNow,
            fileManager: fileManager,
            cacheLifetime: databaseLocationCacheLifetime
        ) {
            candidateURLs.append(cachedURL)
        }

        for url in try locateStateDatabaseCandidates() where !candidateURLs.contains(url) {
            candidateURLs.append(url)
        }

        guard !candidateURLs.isEmpty else {
            throw ReaderError.databaseNotFound
        }

        var lastRetriableError: ReaderError?

        for candidateURL in candidateURLs {
            do {
                let result = try operation(candidateURL)
                stateDatabaseURLCache.store(candidateURL, checkedAt: referenceNow)
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

        let codexDirectory = codexDirectoryURLOverride
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
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

    private func querySnapshotState(
        candidates: Set<String>,
        databaseURL: URL,
        threadUpdateCutoff: Int,
        logCutoff: Int,
        activeTurnCutoff: Int,
        recentProcessCutoff: Int
    ) throws -> SnapshotQueryResult {
        var sections = [
            SQLiteQuerySection(
                name: "activeTurnCount",
                sql: """
                WITH per_process AS (
                    SELECT
                        process_uuid,
                        MAX(ts) AS last_ts,
                        COALESCE(SUM(CASE WHEN message = 'app-server event: turn/started' THEN 1 ELSE 0 END), 0) AS started_count,
                        COALESCE(SUM(CASE WHEN message = 'app-server event: turn/completed' THEN 1 ELSE 0 END), 0) AS completed_count
                    FROM logs
                    WHERE target = 'codex_app_server::outgoing_message'
                      AND ts >= \(activeTurnCutoff)
                    GROUP BY process_uuid
                )
                SELECT MAX(0, COALESCE(MAX(started_count - completed_count), 0))
                FROM per_process
                WHERE last_ts >= \(recentProcessCutoff);
                """
            ),
            SQLiteQuerySection(
                name: "recentUpdates",
                sql: """
                SELECT id
                FROM threads
                WHERE archived = 0
                  AND updated_at >= \(threadUpdateCutoff)
                ORDER BY updated_at DESC
                LIMIT 32;
                """
            ),
            SQLiteQuerySection(
                name: "recentLogs",
                sql: """
                SELECT thread_id
                FROM logs
                WHERE thread_id IS NOT NULL
                  AND ts >= \(logCutoff)
                GROUP BY thread_id;
                """
            )
        ]

        if !candidates.isEmpty {
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
                        FROM logs
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
                        FROM logs
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
        }

        let sectionedOutput = try runSQLiteSections(sections, databaseURL: databaseURL)
        let activeTurnCount = Int(sectionedOutput["activeTurnCount"]?.first ?? "") ?? 0
        let recentUpdatedThreadIDs = parseSQLiteLines(sectionedOutput["recentUpdates"] ?? [])
        let recentLoggedThreadIDs = parseSQLiteLines(sectionedOutput["recentLogs"] ?? [])
        let pendingLogRows = parsePendingLogRows(sectionedOutput["pendingLogs"] ?? [])
        let failedThreads = parseFailedThreads(sectionedOutput["failedThreads"] ?? [])

        return SnapshotQueryResult(
            activeTurnCount: activeTurnCount,
            recentUpdatedThreadIDs: recentUpdatedThreadIDs,
            recentLoggedThreadIDs: recentLoggedThreadIDs,
            pendingLogRows: pendingLogRows,
            failedThreads: failedThreads
        )
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

    private func queryPendingThreadStates(
        candidateSessionPaths: [String: String?],
        logPendingRows: [PendingLogRow]
    ) -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, runningThreadIDs: Set<String>, debugRows: [String]) {
        let logStates = queryLogPendingThreadStates(logPendingRows: logPendingRows)
        let sessionStates = querySessionPendingThreadStates(candidateSessionPaths: candidateSessionPaths)
        let waitingForInputThreadIDs = logStates.waitingForInputThreadIDs.union(sessionStates.waitingForInputThreadIDs)
        let approvalThreadIDs = logStates.approvalThreadIDs.union(sessionStates.approvalThreadIDs)
        let runningThreadIDs = sessionStates.activeTaskThreadIDs
            .subtracting(waitingForInputThreadIDs)
            .subtracting(approvalThreadIDs)

        return (
            waitingForInputThreadIDs: waitingForInputThreadIDs,
            approvalThreadIDs: approvalThreadIDs,
            runningThreadIDs: runningThreadIDs,
            debugRows: logStates.debugRows + sessionStates.debugRows
        )
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
                guard let turnID = payload["turn_id"] as? String else {
                    continue
                }

                if payloadType == "task_started" {
                    // A thread only executes one turn at a time; a newer task start
                    // supersedes any orphaned active turn that never emitted completion.
                    activeTaskIDs = [turnID]
                } else if payloadType == "task_complete" || payloadType == "turn_aborted" {
                    activeTaskIDs.remove(turnID)
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

    private func sqlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func runSQLiteSections(
        _ sections: [SQLiteQuerySection],
        databaseURL: URL
    ) throws -> [String: [String]] {
        let markerPrefix = "__codextension_section__:"
        let combinedSQL = sections
            .map { section in
                """
                SELECT '\(markerPrefix)\(section.name)';
                \(section.sql)
                """
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
            databaseURL.path,
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
            throw ReaderError.queryFailed(message: message ?? "sqlite3 exited with status \(process.terminationStatus)")
        }

        return String(data: outputData, encoding: .utf8) ?? ""
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
        let url: URL
        let checkedAt: Date
    }

    private var entry: Entry?

    func value(
        now: Date,
        fileManager: FileManager,
        cacheLifetime: TimeInterval
    ) -> URL? {
        guard let entry,
              now.timeIntervalSince(entry.checkedAt) < cacheLifetime,
              fileManager.fileExists(atPath: entry.url.path)
        else {
            return nil
        }

        return entry.url
    }

    func store(_ url: URL, checkedAt: Date) {
        entry = Entry(url: url, checkedAt: checkedAt)
    }

    func clear() {
        entry = nil
    }
}

extension CodexDesktopStateReader {
    enum ReaderError: LocalizedError {
        case databaseNotFound
        case queryFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "Could not find a Codex state database in ~/.codex."
            case let .queryFailed(message):
                return message
            }
        }

        var isRetriableDatabaseOpenFailure: Bool {
            switch self {
            case .databaseNotFound:
                return false
            case let .queryFailed(message):
                return message.localizedCaseInsensitiveContains("unable to open database file")
            }
        }
    }
}
