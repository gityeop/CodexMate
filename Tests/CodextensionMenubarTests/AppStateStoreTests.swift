import XCTest
@testable import CodextensionMenubar

final class AppStateStoreTests: XCTestCase {
    func testCodexThreadDeeplinkUsesDesktopRouteFormat() {
        let url = CodexDeepLink.threadURL(threadID: "123e4567-e89b-12d3-a456-426614174000")

        XCTAssertEqual(url?.absoluteString, "codex://threads/123e4567-e89b-12d3-a456-426614174000")
    }

    func testReplaceRecentThreadsSortsNewestFirst() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "older", updatedAt: 100, status: .idle),
            thread(id: "newer", updatedAt: 200, status: .idle),
        ])

        XCTAssertEqual(store.recentThreads.map(\.id), ["newer", "older"])
    }

    func testTurnStartedMarksThreadRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .running)
    }

    func testDesktopRunningOverlayUpdatesUnwatchedThread() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testDesktopPendingOverlayUpdatesUnwatchedThreadFromNotLoaded() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                waitingForInputThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testUserInputRequestMarksWaitingForInput() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testActiveFlagWaitingOnUserInputMapsToWaitingForInput() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .active(flags: [.waitingOnUserInput]))
        ])

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testActiveFlagWaitingOnApprovalMapsToNeedsApproval() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .active(flags: [.waitingOnApproval]))
        ])

        XCTAssertEqual(store.overallStatus, .needsApproval)
        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
    }

    func testDesktopRunningOverlayDoesNotDowngradeWaitingForInput() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testDesktopRunningOverlayDoesNotDowngradeNeedsApproval() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .approval(
            ApprovalRequestPayload(threadId: "thread-1", turnId: "turn-1", itemId: "item-1", reason: nil)
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .needsApproval)
        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
    }

    func testDesktopActiveTurnCountKeepsOverallRunningWithoutThreadOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: []
            )
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.summaryText, "Recent 1 | Watching 0 | Running 1 | Reply 0 | Approval 0")
    }

    func testThreadListRefreshDoesNotLoseWatchedRuntimeStatus() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertTrue(store.recentThreads.first?.isWatched ?? false)
    }

    func testThreadListRefreshPreservesWatchedWaitingForInputWhenIncomingIdle() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testThreadListRefreshPreservesWatchedWaitingForInputWhenIncomingNotLoaded() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testThreadListRefreshPreservesWatchedNeedsApprovalWhenIncomingIdle() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .approval(
            ApprovalRequestPayload(threadId: "thread-1", turnId: "turn-1", itemId: "item-1", reason: nil)
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
    }

    func testWaitingForInputBeatsRunningInOverallStatus() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 100, status: .active(flags: [])),
            thread(id: "waiting", updatedAt: 200, status: .active(flags: [.waitingOnUserInput]))
        ])

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.overallStatus.icon, "💬")
    }

    func testTurnCompletedClearsWaitingForInputToIdle() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
    }

    func testTurnFailureClearsWaitingForInputToFailed() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(
                    id: "turn-1",
                    status: .failed,
                    error: CodexTurnError(message: "boom")
                )
            )
        ))

        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: "boom"))
    }

    func testTurnFailureMarksThreadFailed() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(
                    id: "turn-1",
                    status: .failed,
                    error: CodexTurnError(message: "boom")
                )
            )
        ))

        XCTAssertEqual(store.overallStatus, .failed)
        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: "boom"))
    }

    private func thread(id: String, updatedAt: Int, status: CodexThreadStatus) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt - 10,
            updatedAt: updatedAt,
            status: status,
            cwd: "/tmp/\(id)",
            name: nil
        )
    }
}
