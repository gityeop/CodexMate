import Foundation

struct CodexDesktopRuntimeSnapshot {
    let activeTurnCount: Int
    let runningThreadIDs: Set<String>
    let hasInProgressActivity: Bool
    let lastAppServerEvent: String?
}

struct CodexDesktopStateReader {
    private let fileManager: FileManager
    private let now: () -> Date
    private let recentThreadUpdateInterval: TimeInterval

    init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        recentThreadUpdateInterval: TimeInterval = 8
    ) {
        self.fileManager = fileManager
        self.now = now
        self.recentThreadUpdateInterval = recentThreadUpdateInterval
    }

    func snapshot(candidates: Set<String>) throws -> CodexDesktopRuntimeSnapshot {
        let databaseURL = try locateStateDatabase()
        let nowTimestamp = Int(now().timeIntervalSince1970)
        let threadUpdateCutoff = nowTimestamp - Int(recentThreadUpdateInterval)
        let activeTurnCount = try queryActiveTurnCount(databaseURL: databaseURL)
        let lastAppServerEvent = try queryLatestAppServerEvent(databaseURL: databaseURL)
        let hasInProgressActivity = activeTurnCount > 0 || isInProgressAppServerEvent(lastAppServerEvent)

        guard !candidates.isEmpty else {
            return CodexDesktopRuntimeSnapshot(
                activeTurnCount: activeTurnCount,
                runningThreadIDs: [],
                hasInProgressActivity: hasInProgressActivity,
                lastAppServerEvent: lastAppServerEvent
            )
        }

        guard hasInProgressActivity else {
            return CodexDesktopRuntimeSnapshot(
                activeTurnCount: activeTurnCount,
                runningThreadIDs: [],
                hasInProgressActivity: false,
                lastAppServerEvent: lastAppServerEvent
            )
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

        return CodexDesktopRuntimeSnapshot(
            activeTurnCount: activeTurnCount,
            runningThreadIDs: Set(recentUpdates).intersection(candidates),
            hasInProgressActivity: hasInProgressActivity,
            lastAppServerEvent: lastAppServerEvent
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

    private func queryLatestAppServerEvent(databaseURL: URL) throws -> String? {
        let output = try runSQLite(
            sql: """
            WITH current_process AS (
                SELECT process_uuid
                FROM logs
                WHERE process_uuid IS NOT NULL
                  AND target = 'codex_app_server::outgoing_message'
                ORDER BY ts DESC, ts_nanos DESC, id DESC
                LIMIT 1
            )
            SELECT message
            FROM logs
            WHERE process_uuid = (SELECT process_uuid FROM current_process)
              AND target = 'codex_app_server::outgoing_message'
              AND (
                message LIKE 'app-server event: item/%'
                OR message LIKE 'app-server event: turn/%'
                OR message = 'app-server event: thread/tokenUsage/updated'
                OR message = 'app-server event: account/rateLimits/updated'
              )
            ORDER BY ts DESC, ts_nanos DESC, id DESC
            LIMIT 1;
            """,
            databaseURL: databaseURL
        )

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isInProgressAppServerEvent(_ message: String?) -> Bool {
        guard let message else { return false }

        if message == "app-server event: item/started" || message == "app-server event: turn/started" {
            return true
        }

        if message.hasSuffix("/delta") || message.hasSuffix("/outputDelta") || message.hasSuffix("/terminalInteraction") {
            return true
        }

        return false
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
