import XCTest
@testable import CodextensionMenubar

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
