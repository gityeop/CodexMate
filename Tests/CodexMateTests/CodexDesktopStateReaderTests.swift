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

    func testDefaultSnapshotKeepsUnknownRecentThreadVisibleAcrossIdleRefreshWindow() throws {
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
            VALUES ('thread-1', 'Preview', 'Thread 1', 150, 170, '/tmp/project', NULL, 0);
            """
        )

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 200) },
            stateDatabaseURLOverride: databaseURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: [:])

        XCTAssertEqual(snapshot.recentActivityThreadIDs, ["thread-1"])
    }

    func testSnapshotIncludesMoreThanThirtyTwoRecentUpdatedThreadsWithoutKnownCandidates() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let databaseURL = tempDirectoryURL.appending(path: "state.sqlite")
        let values = (1...40).map { index in
            "('thread-\(index)', 'Preview \(index)', 'Thread \(index)', \(100 + index), \(200 + index), '/tmp/project', NULL, 0)"
        }.joined(separator: ",\n")
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
            VALUES
            \(values);
            """
        )

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 260) },
            recentThreadUpdateInterval: 60,
            stateDatabaseURLOverride: databaseURL
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: [:])

        XCTAssertEqual(snapshot.recentActivityThreadIDs.count, 40)
        XCTAssertTrue(snapshot.recentActivityThreadIDs.contains("thread-1"))
        XCTAssertTrue(snapshot.recentActivityThreadIDs.contains("thread-40"))
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

    func testParseSessionPendingStateMarksUnresolvedEscalatedExecCommandAsApproval() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh\\",\\"justification\\":\\"package app\\",\\"sandbox_permissions\\":\\"require_escalated\\"}","call_id":"call_exec_approval"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: true))
    }

    func testParseSessionPendingStateDoesNotMarkDefaultExecCommandAsApproval() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"swift test\\",\\"workdir\\":\\"/tmp/project\\"}","call_id":"call_exec"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false))
    }

    func testParseSessionPendingStateMarksCamelCaseEscalatedExecCommandAsApproval() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh\\",\\"sandboxPermissions\\":\\"require_escalated\\"}","call_id":"call_exec_approval"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: true))
    }

    func testParseSessionPendingStateClearsEscalatedExecApprovalWhenFunctionCallOutputArrives() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh\\",\\"sandbox_permissions\\":\\"require_escalated\\"}","call_id":"call_exec_approval"}}
        {"timestamp":"2026-03-31T09:42:10.965Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_exec_approval","output":"Rejected(\\"rejected by user\\")"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false))
    }

    func testParseSessionPendingStateMarksExplicitExecApprovalEventAsApproval() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-31T09:40:29.324Z","type":"event_msg","payload":{"type":"exec_approval_request","turn_id":"turn-1","call_id":"call_exec_approval","command":["./scripts/package_app.sh"],"cwd":"/tmp/project","parsed_cmd":[{"type":"literal","value":"./scripts/package_app.sh"}]}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: true, hasActiveTask: true))
    }

    func testParseSessionPendingStateClearsExplicitExecApprovalWhenCommandBegins() {
        let contents = """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-31T09:40:29.324Z","type":"event_msg","payload":{"type":"exec_approval_request","turn_id":"turn-1","call_id":"call_exec_approval","command":["./scripts/package_app.sh"],"cwd":"/tmp/project","parsed_cmd":[{"type":"literal","value":"./scripts/package_app.sh"}]}}
        {"timestamp":"2026-03-31T09:40:35.324Z","type":"event_msg","payload":{"type":"exec_command_begin","call_id":"call_exec_approval","command":"./scripts/package_app.sh","cwd":"/tmp/project","parsed_cmd":[{"type":"literal","value":"./scripts/package_app.sh"}]}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false, hasActiveTask: true))
    }

    func testSQLiteDatabaseArgumentUsesReadOnlyFileURI() {
        let url = URL(fileURLWithPath: "/tmp/Codex State/state 5.sqlite")

        let argument = CodexDesktopStateReader.sqliteDatabaseArgument(for: url)

        XCTAssertTrue(argument.hasPrefix("file://"))
        XCTAssertTrue(argument.contains("mode=ro"))
        XCTAssertFalse(argument.contains("immutable=1"))
        XCTAssertTrue(argument.contains("Codex%20State"))
        XCTAssertTrue(argument.contains("state%205.sqlite"))
    }

    func testParseSessionPendingStateDropsStaleRequestUserInputWhenNewTurnStarts() {
        let contents = """
        {"timestamp":"2026-03-10T19:39:10.465Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_old"}}
        {"timestamp":"2026-03-11T12:16:48.559Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false, hasActiveTask: true))
    }

    func testParseSessionPendingStateKeepsCurrentRequestUserInputAfterNewTurnStarts() {
        let contents = """
        {"timestamp":"2026-03-10T19:39:10.465Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_old"}}
        {"timestamp":"2026-03-11T12:16:48.559Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        {"timestamp":"2026-03-11T12:16:49.559Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_current"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: true, needsApproval: false, hasActiveTask: true))
    }

    func testParseSessionPendingStateClearsRequestUserInputWhenTurnCompletesWithoutOutput() {
        let contents = """
        {"timestamp":"2026-03-11T12:16:48.559Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}
        {"timestamp":"2026-03-11T12:16:49.559Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_current"}}
        {"timestamp":"2026-03-11T12:16:57.725Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false, hasActiveTask: false))
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

    func testSnapshotUsesDesktopCommandExecutionApprovalToSuppressRunning() throws {
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
        {"timestamp":"2026-03-31T09:14:08.377Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let desktopLogsURL = try createDesktopLogDirectory(
            in: tempDirectoryURL,
            year: 2026,
            month: 3,
            day: 31
        )
        let desktopLogURL = desktopLogsURL.appending(path: "codex-desktop.log")
        try """
        2026-03-31T09:14:13.578Z info [electron-message-handler] [desktop-notifications] show approval conversationId=thread-1 kind=commandExecution requestId=14
        """.write(to: desktopLogURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 1_774_948_853) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            stateDatabaseURLOverride: databaseURL,
            desktopLogsDirectoryURLOverride: tempDirectoryURL.appending(path: "desktop-logs", directoryHint: .isDirectory)
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: ["thread-1": sessionURL.path])

        XCTAssertEqual(snapshot.approvalThreadIDs, ["thread-1"])
        XCTAssertEqual(snapshot.runningThreadIDs, [])
    }

    func testSnapshotClearsDesktopCommandExecutionApprovalAfterResponse() throws {
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
        {"timestamp":"2026-03-31T09:14:08.377Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let desktopLogsURL = try createDesktopLogDirectory(
            in: tempDirectoryURL,
            year: 2026,
            month: 3,
            day: 31
        )
        let desktopLogURL = desktopLogsURL.appending(path: "codex-desktop.log")
        try """
        2026-03-31T09:14:13.578Z info [electron-message-handler] [desktop-notifications] show approval conversationId=thread-1 kind=commandExecution requestId=14
        2026-03-31T09:14:23.983Z info [electron-message-handler] Sending server response id=14 method=item/commandExecution/requestApproval response={"decision":"decline"}
        """.write(to: desktopLogURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 1_774_948_853) },
            recentThreadUpdateInterval: 10,
            recentLogInterval: 15,
            stateDatabaseURLOverride: databaseURL,
            desktopLogsDirectoryURLOverride: tempDirectoryURL.appending(path: "desktop-logs", directoryHint: .isDirectory)
        )

        let snapshot = try reader.snapshot(candidateSessionPaths: ["thread-1": sessionURL.path])

        XCTAssertTrue(snapshot.approvalThreadIDs.isEmpty)
        XCTAssertEqual(snapshot.runningThreadIDs, ["thread-1"])
    }

    func testSessionFallbackUsesDesktopCommandExecutionApproval() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let sessionURL = tempDirectoryURL.appending(path: "thread-1.jsonl")
        try """
        {"timestamp":"2026-03-31T09:14:08.377Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let desktopLogsURL = try createDesktopLogDirectory(
            in: tempDirectoryURL,
            year: 2026,
            month: 3,
            day: 31
        )
        let desktopLogURL = desktopLogsURL.appending(path: "codex-desktop.log")
        try """
        2026-03-31T09:14:13.578Z info [electron-message-handler] [desktop-notifications] show approval conversationId=thread-1 kind=commandExecution requestId=14
        """.write(to: desktopLogURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(
            now: { Date(timeIntervalSince1970: 1_774_948_853) },
            desktopLogsDirectoryURLOverride: tempDirectoryURL.appending(path: "desktop-logs", directoryHint: .isDirectory)
        )

        let snapshot = reader.sessionFallbackSnapshot(
            candidateSessionPaths: ["thread-1": sessionURL.path],
            databaseError: "missing db"
        )

        XCTAssertEqual(snapshot?.approvalThreadIDs, ["thread-1"])
        XCTAssertEqual(snapshot?.runningThreadIDs, [])
    }

    func testSessionFallbackUsesEscalatedExecCommandApprovalWithoutDesktopLog() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let sessionURL = tempDirectoryURL.appending(path: "thread-1.jsonl")
        try """
        {"timestamp":"2026-03-31T09:40:28.324Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"2026-03-31T09:40:29.324Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ALLOW_ADHOC_SIGNING=1 ./scripts/package_app.sh\\",\\"justification\\":\\"package app\\",\\"sandbox_permissions\\":\\"require_escalated\\"}","call_id":"call_exec_approval"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopStateReader(now: { Date(timeIntervalSince1970: 1_774_950_000) })

        let snapshot = reader.sessionFallbackSnapshot(
            candidateSessionPaths: ["thread-1": sessionURL.path],
            databaseError: "missing db"
        )

        XCTAssertEqual(snapshot?.approvalThreadIDs, ["thread-1"])
        XCTAssertEqual(snapshot?.runningThreadIDs, [])
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

    func testRecentThreadsReturnsNewestNonArchivedThreads() throws {
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
            ) VALUES
                ('thread-1', 'Preview 1', 'Thread 1', 100, 100, '/tmp/project-1', '/tmp/thread-1.jsonl', 'vscode', NULL, NULL, 0),
                ('thread-2', 'Preview 2', 'Thread 2', 110, 300, '/tmp/project-2', '/tmp/thread-2.jsonl', 'vscode', NULL, NULL, 0),
                ('thread-3', 'Preview 3', 'Thread 3', 120, 200, '/tmp/project-3', '/tmp/thread-3.jsonl', 'vscode', NULL, NULL, 0),
                ('thread-archived', 'Archived', 'Archived Thread', 130, 400, '/tmp/project-4', '/tmp/thread-4.jsonl', 'vscode', NULL, NULL, 1);
            """
        )

        let reader = CodexDesktopStateReader(stateDatabaseURLOverride: databaseURL)
        let threads = try reader.recentThreads(limit: 2)

        XCTAssertEqual(threads.map(\.id), ["thread-2", "thread-3"])
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

    func testReaderErrorTreatsLockedDatabaseFailuresAsRetriable() {
        let locked = CodexDesktopStateReader.ReaderError.queryFailed(
            message: "Error: in prepare, database is locked (5)",
            databasePath: "/tmp/state.sqlite"
        )
        let openFailure = CodexDesktopStateReader.ReaderError.queryFailed(
            message: "Error: in prepare, unable to open database file (14)",
            databasePath: "/tmp/state.sqlite"
        )

        XCTAssertTrue(locked.isRetriableDatabaseOpenFailure)
        XCTAssertTrue(openFailure.isRetriableDatabaseOpenFailure)
    }

    func testCodexDirectoryOverrideTakesPrecedenceOverProvider() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let overrideDirectoryURL = tempDirectoryURL.appending(path: "override-codex-home", directoryHint: .isDirectory)
        let providerDirectoryURL = tempDirectoryURL.appending(path: "provider-codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: overrideDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        try createStateDatabase(
            at: overrideDirectoryURL.appending(path: "state_1.sqlite"),
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
                'override-thread',
                'Override Preview',
                'Override Thread',
                100,
                200,
                '/tmp/override',
                '/tmp/override.jsonl',
                'vscode',
                NULL,
                NULL,
                0
            );
            """
        )

        try createStateDatabase(
            at: providerDirectoryURL.appending(path: "state_1.sqlite"),
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
                'provider-thread',
                'Provider Preview',
                'Provider Thread',
                100,
                300,
                '/tmp/provider',
                '/tmp/provider.jsonl',
                'vscode',
                NULL,
                NULL,
                0
            );
            """
        )

        let reader = CodexDesktopStateReader(
            codexDirectoryURLOverride: overrideDirectoryURL,
            codexDirectoryURLProvider: { providerDirectoryURL }
        )

        let threads = try reader.recentThreads(limit: 1)

        XCTAssertEqual(threads.map(\.id), ["override-thread"])
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

    private func createDesktopLogDirectory(
        in rootDirectoryURL: URL,
        year: Int,
        month: Int,
        day: Int
    ) throws -> URL {
        let directoryURL = rootDirectoryURL
            .appending(path: "desktop-logs", directoryHint: .isDirectory)
            .appending(path: String(format: "%04d", year), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", month), directoryHint: .isDirectory)
            .appending(path: String(format: "%02d", day), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
