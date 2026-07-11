import Foundation
import XCTest
@testable import CodexMate

final class ThreadNotificationPlannerTests: XCTestCase {
    var temporaryDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
        try super.tearDownWithError()
    }

    func testCompletionNotificationRequiresRunningOrPendingPreviousStatus() {
        let rows = [
            row(id: "thread-a", status: .idle),
            row(id: "thread-b", status: .idle)
        ]

        let notifications = ThreadNotificationPlanner.notifications(
            previousStatusByThreadID: [
                "thread-a": .running,
                "thread-b": .idle
            ],
            currentRows: rows
        )

        XCTAssertEqual(
            notifications,
            [
                ThreadDesktopNotification(threadID: "thread-a", kind: .completion)
            ]
        )
    }

    func testAttentionNotificationEmitsForNewPendingStatusOnce() {
        let rows = [
            row(id: "thread-a", status: .waitingForInput),
            row(id: "thread-b", status: .needsApproval),
            row(id: "thread-c", status: .needsApproval)
        ]

        let notifications = ThreadNotificationPlanner.notifications(
            previousStatusByThreadID: [
                "thread-a": .running,
                "thread-c": .needsApproval
            ],
            currentRows: rows
        )

        XCTAssertEqual(
            notifications,
            [
                ThreadDesktopNotification(threadID: "thread-a", kind: .attention(.waitingForInput)),
                ThreadDesktopNotification(threadID: "thread-b", kind: .attention(.needsApproval))
            ]
        )
    }

    func testFailureNotificationIncludesMessageAndDoesNotRepeatUnchangedFailure() {
        let rows = [
            row(id: "thread-a", status: .failed(message: "boom")),
            row(id: "thread-b", status: .failed(message: "same"))
        ]

        let notifications = ThreadNotificationPlanner.notifications(
            previousStatusByThreadID: [
                "thread-a": .running,
                "thread-b": .failed(message: "same")
            ],
            currentRows: rows
        )

        XCTAssertEqual(
            notifications,
            [
                ThreadDesktopNotification(threadID: "thread-a", kind: .failure(message: "boom"))
            ]
        )
    }

    func testSubagentRowsNeverEmitNotifications() {
        let rows = [
            row(id: "main", status: .idle),
            row(id: "subagent-completed", status: .idle, isSubagent: true),
            row(id: "subagent-waiting", status: .waitingForInput, isSubagent: true),
            row(id: "subagent-failed", status: .failed(message: "boom"), isSubagent: true)
        ]

        let notifications = ThreadNotificationPlanner.notifications(
            previousStatusByThreadID: [
                "main": .running,
                "subagent-completed": .running,
                "subagent-waiting": .running,
                "subagent-failed": .running
            ],
            currentRows: rows
        )

        XCTAssertEqual(
            notifications,
            [ThreadDesktopNotification(threadID: "main", kind: .completion)]
        )
    }

    func testStatusByThreadIDUsesDisplayStatus() {
        var waitingRow = row(id: "thread-a", status: .idle)
        waitingRow.pendingRequestKind = .approval

        XCTAssertEqual(
            ThreadNotificationPlanner.statusByThreadID(from: [waitingRow]),
            ["thread-a": .needsApproval]
        )
    }

    func testLatestAssistantReplySnippetReadsLastAssistantMessage() throws {
        let sessionURL = temporaryDirectoryURL.appending(path: "session.jsonl")
        try """
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":"older answer"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"question"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"newer answer\\nwith spacing"}]}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ThreadNotificationContentBuilder.latestAssistantReplySnippet(sessionPath: sessionURL.path),
            "newer answer with spacing"
        )
    }

    func testLatestAssistantReplySnippetCompactsAndTruncatesLongOutput() throws {
        let sessionURL = temporaryDirectoryURL.appending(path: "long-session.jsonl")
        let longAnswer = String(repeating: "a", count: 220)
        try """
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":"\(longAnswer)"}}
        """.write(to: sessionURL, atomically: true, encoding: .utf8)

        let snippet = try XCTUnwrap(
            ThreadNotificationContentBuilder.latestAssistantReplySnippet(sessionPath: sessionURL.path)
        )

        XCTAssertEqual(snippet.count, 183)
        XCTAssertTrue(snippet.hasSuffix("..."))
    }

    func testNotificationContentUsesProjectTitleAndCompletionAnswer() {
        let content = ThreadNotificationContentBuilder.content(
            body: "",
            metadata: ThreadNotificationMetadata(
                projectDisplayName: "CodexMate",
                threadTitle: "Ship notifications",
                replySnippet: "Implemented clickable notifications."
            ),
            kind: .completion
        )

        XCTAssertEqual(content.title, "CodexMate")
        XCTAssertEqual(content.subtitle, "Ship notifications")
        XCTAssertEqual(content.body, "Implemented clickable notifications.")
    }

    private func row(
        id: String,
        status: AppStateStore.ThreadStatus,
        isSubagent: Bool = false
    ) -> AppStateStore.ThreadRow {
        var row = AppStateStore.ThreadRow(
            id: id,
            displayTitle: id,
            preview: id,
            cwd: "/tmp",
            status: status,
            listedStatus: status,
            updatedAt: Date(timeIntervalSince1970: 100),
            isWatched: true
        )
        row.isSubagent = isSubagent
        return row
    }
}
