import XCTest
@testable import CodexMate

final class DesktopActivityServiceTests: XCTestCase {
    func testLoadMergesAppServerCompletionHintsFromRuntimeSnapshot() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logsDirectoryURL = tempDirectoryURL.appending(path: "desktop-logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let databaseURL = tempDirectoryURL.appending(path: "state.sqlite")
        try createStateDatabase(
            at: databaseURL,
            sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                first_user_message TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                cwd TEXT NOT NULL,
                rollout_path TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                process_uuid TEXT,
                target TEXT,
                message TEXT,
                ts INTEGER NOT NULL,
                ts_nanos INTEGER NOT NULL DEFAULT 0,
                thread_id TEXT
            );
            INSERT INTO threads (id, first_user_message, title, created_at, updated_at, cwd, rollout_path, archived)
            VALUES ('thread-1', 'Preview', 'Thread 1', 150, 195, '/tmp/project', NULL, 0);
            INSERT INTO logs (process_uuid, target, message, ts, ts_nanos, thread_id)
            VALUES ('process-1', 'codex_app_server::outgoing_message', 'app-server event: turn/completed', 198, 0, 'thread-1');
            """
        )

        let service = DesktopActivityService(
            stateReader: CodexDesktopStateReader(
                now: { Date(timeIntervalSince1970: 200) },
                stateDatabaseURLOverride: databaseURL
            ),
            conversationActivityReader: CodexDesktopConversationActivityReader(
                logsDirectoryURL: logsDirectoryURL,
                lookbackDays: 1
            )
        )

        let update = await service.load(
            candidateSessionPaths: ["thread-1": nil],
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(update.latestTurnCompletedAtByThreadID["thread-1"], Date(timeIntervalSince1970: 198))
        XCTAssertEqual(
            update.runtimeSnapshot?.latestTurnCompletedAtByThreadID["thread-1"],
            Date(timeIntervalSince1970: 198)
        )
    }

    func testLoadPassesThroughDesktopArchiveAndUnarchiveHints() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let logsDirectoryURL = tempDirectoryURL.appending(path: "desktop-logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = logsDirectoryURL
            .appending(path: "2026")
            .appending(path: "04")
            .appending(path: "12")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "archive.log")
        try """
        2026-04-12T03:05:25.512Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=22 errorCode=null hadInternalHandler=false hadPending=true method=thread/archive originWebcontentsId=1 requestId=a targetDestroyed=false
        2026-04-12T03:05:30.512Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=22 errorCode=null hadInternalHandler=false hadPending=true method=thread/unarchive originWebcontentsId=1 requestId=b targetDestroyed=false
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let databaseURL = tempDirectoryURL.appending(path: "state.sqlite")
        try createStateDatabase(
            at: databaseURL,
            sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                first_user_message TEXT NOT NULL DEFAULT '',
                title TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                cwd TEXT NOT NULL,
                rollout_path TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                process_uuid TEXT,
                target TEXT,
                message TEXT,
                ts INTEGER NOT NULL,
                ts_nanos INTEGER NOT NULL DEFAULT 0,
                thread_id TEXT
            );
            INSERT INTO threads (id, first_user_message, title, created_at, updated_at, cwd, rollout_path, archived)
            VALUES ('thread-1', 'Preview', 'Thread 1', 150, 195, '/tmp/project', NULL, 0);
            """
        )

        let service = DesktopActivityService(
            stateReader: CodexDesktopStateReader(
                now: { Date(timeIntervalSince1970: 200) },
                stateDatabaseURLOverride: databaseURL
            ),
            conversationActivityReader: CodexDesktopConversationActivityReader(
                logsDirectoryURL: logsDirectoryURL,
                lookbackDays: 1
            )
        )

        let update = await service.load(
            candidateSessionPaths: ["thread-1": nil],
            now: date("2026-04-12T03:06:00.000Z") ?? .distantPast
        )

        XCTAssertEqual(
            update.latestArchiveRequestedAtByThreadID["thread-1"],
            date("2026-04-12T03:05:25.512Z")
        )
        XCTAssertEqual(
            update.latestUnarchiveRequestedAtByThreadID["thread-1"],
            date("2026-04-12T03:05:30.512Z")
        )
    }

    func testDatabaseFailureFallsBackToSessionPendingApprovalSnapshot() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let missingDatabaseURL = tempDirectoryURL.appending(path: "missing-state.sqlite")
        let sessionURL = tempDirectoryURL.appending(path: "thread-1.jsonl")
        try """
        {"timestamp":"2026-03-29T08:44:27.014Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-29T08:44:27.015Z","type":"response_item","payload":{"type":"function_call","name":"request_approval","arguments":"{}","call_id":"call-approval"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let service = DesktopActivityService(
            stateReader: CodexDesktopStateReader(stateDatabaseURLOverride: missingDatabaseURL)
        )

        let update = await service.load(
            candidateSessionPaths: ["thread-1": sessionURL.path],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(update.runtimeErrorMessage)
        XCTAssertEqual(update.runtimeSnapshot?.approvalThreadIDs, ["thread-1"])
        XCTAssertTrue(update.runtimeSnapshot?.waitingForInputThreadIDs.isEmpty ?? false)
        XCTAssertEqual(update.runtimeSnapshot?.runningThreadIDs, [])
    }

    func testRepeatedDatabaseOpenFailuresAreThrottled() async {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "state.sqlite")

        let service = DesktopActivityService(
            stateReader: CodexDesktopStateReader(stateDatabaseURLOverride: missingDatabaseURL)
        )

        let first = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 100)
        )
        let second = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 110)
        )
        let third = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 131)
        )

        XCTAssertNotNil(first.runtimeErrorMessage)
        XCTAssertNil(second.runtimeErrorMessage)
        XCTAssertNotNil(third.runtimeErrorMessage)
    }

    func testLockedDatabaseErrorsAreRetriable() {
        let error = CodexDesktopStateReader.ReaderError.queryFailed(
            message: "Error: in prepare, database is locked (5)",
            databasePath: "/tmp/state.sqlite"
        )

        XCTAssertTrue(error.isRetriableDatabaseOpenFailure)
    }

    private func createStateDatabase(at databaseURL: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            XCTFail(errorMessage)
            return
        }
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
