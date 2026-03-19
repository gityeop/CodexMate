import XCTest
@testable import CodexMate

final class CodexDesktopStateReaderTests: XCTestCase {
    func testSnapshotIncludesRecentActivityThreadIDsWithoutKnownCandidates() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
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
            """
        )

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 200) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            stateDatabaseURLOverride: databaseURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: [:])

        XCTAssertEqual(snapshot.recentActivityThreadIDs, ["thread-1"])
        XCTAssertTrue(snapshot.runningThreadIDs.isEmpty)
    }

    func testParseSessionPendingStateMarksUnresolvedRequestUserInputAsWaiting() {
        let contents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_waiting"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: true, needsApproval: false))
    }

    func testParseSessionPendingStateClearsWaitingWhenFunctionCallOutputArrives() {
        let contents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_waiting"}}
        {"timestamp":"2026-03-11T12:50:10.223Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_waiting","output":"{\\"answers\\":{}}"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false))
    }

    func testParseSessionPendingStateTracksIncompleteTaskLifecycle() {
        let runningContents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """
        let completedContents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-11T12:50:10.223Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
        """

        XCTAssertEqual(
            CodexDesktopStateReader.parseSessionPendingState(from: runningContents),
            .init(waitingForInput: false, needsApproval: false, hasActiveTask: true)
        )
        XCTAssertEqual(
            CodexDesktopStateReader.parseSessionPendingState(from: completedContents),
            .init(waitingForInput: false, needsApproval: false, hasActiveTask: false)
        )
    }

    func testParseSessionPendingStateClearsActiveTaskWhenTurnIsAborted() {
        let contents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-11T12:25:25.936Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false, hasActiveTask: false))
    }

    func testParseSessionPendingStateSupersedesOlderUnfinishedTaskWhenNewTurnStarts() {
        let contents = """
        {"timestamp":"2026-03-10T19:39:10.465Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-11T12:16:48.559Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        {"timestamp":"2026-03-11T12:16:57.725Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false, hasActiveTask: false))
    }

    func testSnapshotKeepsSessionBackedRunningThreadEvenWhenDesktopLogsAreQuiet() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
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
            VALUES ('thread-1', 'Preview', 'Thread 1', 150, 150, '/tmp/project', NULL, 0);
            """
        )

        let sessionURL = tempDirectoryURL.appending(path: "thread-1.jsonl")
        try """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 200) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            stateDatabaseURLOverride: databaseURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: ["thread-1": sessionURL.path])

        XCTAssertEqual(snapshot.activeTurnCount, 0)
        XCTAssertEqual(snapshot.runningThreadIDs, ["thread-1"])
        XCTAssertTrue(snapshot.waitingForInputThreadIDs.isEmpty)
        XCTAssertTrue(snapshot.approvalThreadIDs.isEmpty)
    }

    func testThreadsLoadSubagentMetadata() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
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
                source TEXT NOT NULL DEFAULT 'vscode',
                agent_role TEXT,
                agent_nickname TEXT,
                archived INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads (
                id,
                first_user_message,
                title,
                created_at,
                updated_at,
                cwd,
                rollout_path,
                source,
                agent_role,
                agent_nickname,
                archived
            ) VALUES (
                'thread-1',
                'Preview',
                'Thread 1',
                150,
                195,
                '/tmp/project',
                '/tmp/thread-1.jsonl',
                '{"subagent":{"thread_spawn":{"parent_thread_id":"parent-1","depth":1,"agent_nickname":"Harvey","agent_role":"explorer"}}}',
                'explorer',
                'Harvey',
                0
            );
            """
        )

        let reader = CodexDesktopStateReader(stateDatabaseURLOverride: databaseURL)
        let threads = try reader.threads(threadIDs: ["thread-1"])

        XCTAssertEqual(threads.first?.agentRole, "explorer")
        XCTAssertEqual(threads.first?.agentNickname, "Harvey")
        XCTAssertTrue(threads.first?.isSubagent ?? false)
    }

    func testSnapshotDoesNotTreatPendingSessionTaskAsRunning() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
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
            VALUES ('thread-1', 'Preview', 'Thread 1', 150, 150, '/tmp/project', NULL, 0);
            """
        )

        let sessionURL = tempDirectoryURL.appending(path: "thread-1.jsonl")
        try """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-11T12:25:25.936Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_waiting"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 200) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            stateDatabaseURLOverride: databaseURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: ["thread-1": sessionURL.path])

        XCTAssertEqual(snapshot.runningThreadIDs, [])
        XCTAssertEqual(snapshot.waitingForInputThreadIDs, ["thread-1"])
    }

    func testSnapshotFallsBackToOlderStateDatabaseWhenNewestCandidateCannotBeOpened() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let goodDatabaseURL = tempDirectoryURL.appending(path: "state_1.sqlite")
        try createStateDatabase(
            at: goodDatabaseURL,
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

        let unreadableDatabaseURL = tempDirectoryURL.appending(path: "state_2.sqlite", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unreadableDatabaseURL, withIntermediateDirectories: true)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: goodDatabaseURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: unreadableDatabaseURL.path
        )

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 200) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            codexDirectoryURLOverride: tempDirectoryURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: [:])

        XCTAssertEqual(snapshot.recentActivityThreadIDs, ["thread-1"])
        XCTAssertTrue(snapshot.runningThreadIDs.isEmpty)
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
}
