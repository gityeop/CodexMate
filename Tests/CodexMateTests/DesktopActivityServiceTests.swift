import XCTest
@testable import CodexMate

final class DesktopActivityServiceTests: XCTestCase {
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
}
