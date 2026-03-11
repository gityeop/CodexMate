import Foundation

struct CodexDesktopRuntimeSnapshot {
    struct FailedThreadState {
        let message: String
        let loggedAt: Date
    }

    let activeTurnCount: Int
    let runningThreadIDs: Set<String>
    let waitingForInputThreadIDs: Set<String>
    let approvalThreadIDs: Set<String>
    let failedThreads: [String: FailedThreadState]
    let debugSummary: String

    init(
        activeTurnCount: Int,
        runningThreadIDs: Set<String>,
        waitingForInputThreadIDs: Set<String> = [],
        approvalThreadIDs: Set<String> = [],
        failedThreads: [String: FailedThreadState] = [:],
        debugSummary: String = ""
    ) {
        self.activeTurnCount = activeTurnCount
        self.runningThreadIDs = runningThreadIDs
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
    }

    private let fileManager: FileManager
    private let now: () -> Date
    private let recentThreadUpdateInterval: TimeInterval
    private let recentLogInterval: TimeInterval
    private let sessionPendingStateCache = SessionPendingStateCache()

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        recentThreadUpdateInterval: TimeInterval = 10,
        recentLogInterval: TimeInterval = 15
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentThreadUpdateInterval = recentThreadUpdateInterval
        self.recentLogInterval = recentLogInterval
    }

    func snapshot(candidates: Set<String>) throws -> CodexDesktopRuntimeSnapshot {
        try snapshot(candidateSessionPaths: Dictionary(uniqueKeysWithValues: candidates.map { ($0, nil) }))
    }

    func snapshot(candidateSessionPaths: [String: String?]) throws -> CodexDesktopRuntimeSnapshot {
        let databaseURL = try locateStateDatabase()
        let candidates = Set(candidateSessionPaths.keys)
        let nowTimestamp = Int(now().timeIntervalSince1970)
        let threadUpdateCutoff = nowTimestamp - Int(recentThreadUpdateInterval)
        let logCutoff = nowTimestamp - Int(recentLogInterval)
        let activeTurnCount = try queryActiveTurnCount(databaseURL: databaseURL)

        guard !candidates.isEmpty else {
            return CodexDesktopRuntimeSnapshot(activeTurnCount: activeTurnCount, runningThreadIDs: [])
        }

        let recentUpdates = try queryThreadIDs(
            sql: """
            SELECT id
            FROM threads
            WHERE archived = 0
              AND updated_at >= \(threadUpdateCutoff)
            ORDER BY updated_at DESC
            LIMIT 32;
            """,
            databaseURL: databaseURL
        )

        let recentLogs = try queryThreadIDs(
            sql: """
            SELECT thread_id
            FROM logs
            WHERE thread_id IS NOT NULL
              AND ts >= \(logCutoff)
            GROUP BY thread_id;
            """,
            databaseURL: databaseURL
        )

        let pendingStates = try queryPendingThreadStates(
            candidates: candidates,
            candidateSessionPaths: candidateSessionPaths,
            databaseURL: databaseURL
        )
        let failedThreads = try queryFailedThreads(candidates: candidates, databaseURL: databaseURL)
        let debugSummary = [
            "candidates=\(candidates.count)",
            "waiting=\(pendingStates.waitingForInputThreadIDs.count)",
            "approval=\(pendingStates.approvalThreadIDs.count)",
            "failed=\(failedThreads.count)",
            "rows=\(pendingStates.debugRows.count)",
            "sample=\(pendingStates.debugRows.isEmpty ? "[]" : "[" + pendingStates.debugRows.prefix(3).joined(separator: ", ") + (pendingStates.debugRows.count > 3 ? ", +\(pendingStates.debugRows.count - 3)" : "") + "]")"
        ].joined(separator: " ")

        let runningThreadIDs: Set<String>
        if activeTurnCount > 0 {
            runningThreadIDs = Set(recentUpdates + recentLogs).intersection(candidates)
        } else {
            runningThreadIDs = []
        }

        return CodexDesktopRuntimeSnapshot(
            activeTurnCount: activeTurnCount,
            runningThreadIDs: runningThreadIDs,
            waitingForInputThreadIDs: pendingStates.waitingForInputThreadIDs,
            approvalThreadIDs: pendingStates.approvalThreadIDs,
            failedThreads: failedThreads,
            debugSummary: debugSummary
        )
    }

    private func locateStateDatabase() throws -> URL {
        let codexDirectory = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let candidateURLs = try fileManager.contentsOfDirectory(
            at: codexDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.lastPathComponent.hasPrefix("state_") && url.pathExtension == "sqlite"
        }

        guard let databaseURL = candidateURLs.max(by: { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            throw ReaderError.databaseNotFound
        }

        return databaseURL
    }

    private func queryThreadIDs(sql: String, databaseURL: URL) throws -> [String] {
        let output = try runSQLite(sql: sql, databaseURL: databaseURL)
        return output
            .split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func queryActiveTurnCount(databaseURL: URL) throws -> Int {
        let output = try runSQLite(
            sql: """
            WITH current_process AS (
                SELECT process_uuid
                FROM logs
                WHERE target = 'codex_app_server::outgoing_message'
                ORDER BY ts DESC, ts_nanos DESC, id DESC
                LIMIT 1
            )
            SELECT MAX(
                0,
                COALESCE(SUM(CASE WHEN message = 'app-server event: turn/started' THEN 1 ELSE 0 END), 0) -
                COALESCE(SUM(CASE WHEN message = 'app-server event: turn/completed' THEN 1 ELSE 0 END), 0)
            )
            FROM logs
            WHERE target = 'codex_app_server::outgoing_message'
              AND process_uuid = (SELECT process_uuid FROM current_process);
            """,
            databaseURL: databaseURL
        )

        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func queryPendingThreadStates(
        candidates: Set<String>,
        candidateSessionPaths: [String: String?],
        databaseURL: URL
    ) throws -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, debugRows: [String]) {
        let logStates = try queryLogPendingThreadStates(candidates: candidates, databaseURL: databaseURL)
        let sessionStates = querySessionPendingThreadStates(candidateSessionPaths: candidateSessionPaths)

        return (
            waitingForInputThreadIDs: logStates.waitingForInputThreadIDs.union(sessionStates.waitingForInputThreadIDs),
            approvalThreadIDs: logStates.approvalThreadIDs.union(sessionStates.approvalThreadIDs),
            debugRows: logStates.debugRows + sessionStates.debugRows
        )
    }

    private func queryLogPendingThreadStates(candidates: Set<String>, databaseURL: URL) throws -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, debugRows: [String]) {
        let candidateList = candidates
            .map(sqlQuoted)
            .sorted()
            .joined(separator: ", ")

        let output = try runSQLite(
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
            """,
            databaseURL: databaseURL
        )

        var waitingThreadIDs: Set<String> = []
        var approvalThreadIDs: Set<String> = []
        var debugRows: [String] = []

        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let threadID = object["thread_id"] as? String,
                  let message = object["message"] as? String
            else {
                continue
            }

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
    ) -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, debugRows: [String]) {
        var waitingThreadIDs: Set<String> = []
        var approvalThreadIDs: Set<String> = []
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
        }

        return (waitingThreadIDs, approvalThreadIDs, debugRows)
    }

    func sessionPendingState(forSessionFileAt sessionURL: URL) -> SessionPendingState? {
        let modificationDate = (try? sessionURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        if let cached = sessionPendingStateCache.value(for: sessionURL.path, modificationDate: modificationDate) {
            return cached
        }

        guard let contents = try? String(contentsOf: sessionURL, encoding: .utf8) else {
            return nil
        }

        let state = Self.parseSessionPendingState(from: contents)
        sessionPendingStateCache.store(state, for: sessionURL.path, modificationDate: modificationDate)
        return state
    }

    static func parseSessionPendingState(from contents: String) -> SessionPendingState {
        var unresolvedRequestUserInputCallIDs: Set<String> = []
        var unresolvedApprovalCallIDs: Set<String> = []

        for line in contents.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "response_item",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String
            else {
                continue
            }

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
        }

        return SessionPendingState(
            waitingForInput: !unresolvedRequestUserInputCallIDs.isEmpty,
            needsApproval: !unresolvedApprovalCallIDs.isEmpty
        )
    }

    private func queryFailedThreads(candidates: Set<String>, databaseURL: URL) throws -> [String: CodexDesktopRuntimeSnapshot.FailedThreadState] {
        let candidateList = candidates
            .map(sqlQuoted)
            .sorted()
            .joined(separator: ", ")

        let output = try runSQLite(
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
            """,
            databaseURL: databaseURL
        )

        var failedThreads: [String: CodexDesktopRuntimeSnapshot.FailedThreadState] = [:]

        for line in output.split(separator: "\n") {
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

    private func sqlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
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
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderError.queryFailed(message: message ?? "sqlite3 exited with status \(process.terminationStatus)")
        }

        return String(data: outputData, encoding: .utf8) ?? ""
    }
}

private final class SessionPendingStateCache {
    private struct Entry {
        let modificationDate: Date?
        let state: CodexDesktopStateReader.SessionPendingState
    }

    private var entries: [String: Entry] = [:]

    func value(for path: String, modificationDate: Date?) -> CodexDesktopStateReader.SessionPendingState? {
        guard let entry = entries[path], entry.modificationDate == modificationDate else {
            return nil
        }

        return entry.state
    }

    func store(_ state: CodexDesktopStateReader.SessionPendingState, for path: String, modificationDate: Date?) {
        entries[path] = Entry(modificationDate: modificationDate, state: state)
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
    }
}
