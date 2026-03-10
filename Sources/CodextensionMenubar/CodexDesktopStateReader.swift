import Foundation

struct CodexDesktopRuntimeSnapshot {
    let activeTurnCount: Int
    let runningThreadIDs: Set<String>
    let waitingForInputThreadIDs: Set<String>
    let approvalThreadIDs: Set<String>
    let debugSummary: String

    init(
        activeTurnCount: Int,
        runningThreadIDs: Set<String>,
        waitingForInputThreadIDs: Set<String> = [],
        approvalThreadIDs: Set<String> = [],
        debugSummary: String = ""
    ) {
        self.activeTurnCount = activeTurnCount
        self.runningThreadIDs = runningThreadIDs
        self.waitingForInputThreadIDs = waitingForInputThreadIDs
        self.approvalThreadIDs = approvalThreadIDs
        self.debugSummary = debugSummary
    }
}

struct CodexDesktopStateReader {
    private let fileManager: FileManager
    private let now: () -> Date
    private let recentThreadUpdateInterval: TimeInterval
    private let recentLogInterval: TimeInterval

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        recentThreadUpdateInterval: TimeInterval = 3,
        recentLogInterval: TimeInterval = 6
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentThreadUpdateInterval = recentThreadUpdateInterval
        self.recentLogInterval = recentLogInterval
    }

    func snapshot(candidates: Set<String>) throws -> CodexDesktopRuntimeSnapshot {
        let databaseURL = try locateStateDatabase()
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

        let pendingStates = try queryPendingThreadStates(candidates: candidates, databaseURL: databaseURL)
        let debugSummary = [
            "candidates=\(candidates.count)",
            "waiting=\(pendingStates.waitingForInputThreadIDs.count)",
            "approval=\(pendingStates.approvalThreadIDs.count)",
            "rows=\(pendingStates.debugRows.count)",
            "sample=\(pendingStates.debugRows.isEmpty ? "[]" : "[" + pendingStates.debugRows.prefix(3).joined(separator: ", ") + (pendingStates.debugRows.count > 3 ? ", +\(pendingStates.debugRows.count - 3)" : "") + "]")"
        ].joined(separator: " ")

        return CodexDesktopRuntimeSnapshot(
            activeTurnCount: activeTurnCount,
            runningThreadIDs: Set(recentUpdates + recentLogs).intersection(candidates),
            waitingForInputThreadIDs: pendingStates.waitingForInputThreadIDs,
            approvalThreadIDs: pendingStates.approvalThreadIDs,
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

    private func queryPendingThreadStates(candidates: Set<String>, databaseURL: URL) throws -> (waitingForInputThreadIDs: Set<String>, approvalThreadIDs: Set<String>, debugRows: [String]) {
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
