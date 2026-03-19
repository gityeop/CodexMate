import XCTest
@testable import CodexMate

final class MenubarStatusPresentationTests: XCTestCase {
    func testStatusItemIconUsesBlueDotForUnreadIdleState() {
        XCTAssertEqual(
            MenubarStatusPresentation.statusItemIcon(overallStatus: .idle, hasUnreadThreads: true),
            "🔵"
        )
        XCTAssertEqual(
            MenubarStatusPresentation.statusItemIcon(overallStatus: .running, hasUnreadThreads: true),
            "⏳"
        )
        XCTAssertEqual(
            MenubarStatusPresentation.statusItemIcon(overallStatus: .failed, hasUnreadThreads: true),
            "🔵"
        )
    }

    func testThreadTitleOmitsIdleSymbol() {
        let title = MenubarStatusPresentation.threadTitle(
            for: threadRow(status: .idle),
            relativeDate: "1m ago"
        )

        XCTAssertEqual(title, "Thread title | 1m ago")
    }

    func testThreadTitleOmitsRunningSymbolAndLeavesIconToIndicatorSlot() {
        let title = MenubarStatusPresentation.threadTitle(
            for: threadRow(status: .running, activeTurnID: "turn-1"),
            relativeDate: "1m ago"
        )

        XCTAssertEqual(title, "Thread title | 1m ago")
    }

    func testThreadTitleTruncatesDisplayTitleButKeepsRelativeDate() {
        let title = MenubarStatusPresentation.threadTitle(
            for: threadRow(
                status: .idle,
                displayTitle: "This is a very long thread title that should not stretch the menu forever"
            ),
            relativeDate: "1m ago",
            maxDisplayTitleLength: 20
        )

        XCTAssertEqual(title, "This is a very long… | 1m ago")
    }

    func testProjectSectionTitleTruncatesDisplayNameButKeepsThreadCount() {
        let title = MenubarStatusPresentation.projectSectionTitle(
            displayName: "feature/super-long-worktree-name-for-testing",
            threadCount: 3,
            maxDisplayNameLength: 18
        )

        XCTAssertEqual(title, "feature/super-lon… | 3 threads")
    }

    func testThreadTooltipUsesWorktreeFirstMinimalContent() {
        let tooltip = MenubarStatusPresentation.threadTooltip(
            worktreeDisplayName: "feature/parser-menu",
            thread: threadRow(
                status: .idle,
                displayTitle: "Fix hover copy",
                preview: "Tighten thread tooltip text"
            )
        )

        XCTAssertEqual(
            tooltip,
            """
            Worktree: feature/parser-menu
            Fix hover copy
            Tighten thread tooltip text
            """
        )
    }

    func testThreadTooltipOmitsPreviewWhenItMatchesTitle() {
        let tooltip = MenubarStatusPresentation.threadTooltip(
            worktreeDisplayName: "feature/parser-menu",
            thread: threadRow(
                status: .idle,
                displayTitle: "Same text",
                preview: "Same text"
            )
        )

        XCTAssertEqual(
            tooltip,
            """
            Worktree: feature/parser-menu
            Same text
            """
        )
    }

    func testThreadTooltipShowsApprovalReasonBeforePreview() {
        let tooltip = MenubarStatusPresentation.threadTooltip(
            worktreeDisplayName: "feature/parser-menu",
            thread: threadRow(
                status: .idle,
                displayTitle: "Ship parser menu",
                preview: "Needs escalation for signing",
                pendingRequestKind: .approval,
                pendingRequestReason: "Sign the release artifact"
            )
        )

        XCTAssertEqual(
            tooltip,
            """
            Worktree: feature/parser-menu
            Ship parser menu
            Approval: Sign the release artifact
            Needs escalation for signing
            """
        )
    }

    func testThreadTooltipShowsErrorBeforePreview() {
        let tooltip = MenubarStatusPresentation.threadTooltip(
            worktreeDisplayName: "feature/parser-menu",
            thread: threadRow(
                status: .failed(message: "Request timed out"),
                displayTitle: "Retry parser sync",
                preview: "Last retry failed after 30s"
            )
        )

        XCTAssertEqual(
            tooltip,
            """
            Worktree: feature/parser-menu
            Retry parser sync
            Error: Request timed out
            Last retry failed after 30s
            """
        )
    }

    func testThreadTooltipDoesNotIncludePath() {
        let tooltip = MenubarStatusPresentation.threadTooltip(
            worktreeDisplayName: "feature/parser-menu",
            thread: threadRow(
                status: .idle,
                displayTitle: "Fix hover copy",
                preview: "Tighten thread tooltip text",
                cwd: "/Users/tester/workspaces/codexmate"
            )
        )

        XCTAssertFalse(tooltip.contains("/Users/tester/workspaces/codexmate"))
    }

    func testThreadIndicatorUsesUnreadDotForUnreadIdleThread() {
        XCTAssertEqual(
            MenubarStatusPresentation.threadIndicator(
                for: threadRow(status: .idle),
                hasUnreadContent: true
            ),
            .unread
        )
    }

    func testThreadIndicatorUsesRunningStateForActiveThread() {
        XCTAssertEqual(
            MenubarStatusPresentation.threadIndicator(
                for: threadRow(status: .running, activeTurnID: "turn-1"),
                hasUnreadContent: false
            ),
            .running
        )
    }

    func testThreadIndicatorUsesWaitingForUserForApprovalAndInputStates() {
        XCTAssertEqual(
            MenubarStatusPresentation.threadIndicator(
                for: threadRow(status: .waitingForInput),
                hasUnreadContent: false
            ),
            .waitingForUser
        )
        XCTAssertEqual(
            MenubarStatusPresentation.threadIndicator(
                for: threadRow(status: .needsApproval),
                hasUnreadContent: false
            ),
            .waitingForUser
        )
    }

    private static func threadRow(
        status: AppStateStore.ThreadStatus,
        displayTitle: String = "Thread title",
        preview: String = "Preview",
        cwd: String = "/tmp/thread-1",
        pendingRequestKind: AppStateStore.PendingRequestKind? = nil,
        pendingRequestReason: String? = nil,
        activeTurnID: String? = nil
    ) -> AppStateStore.ThreadRow {
        AppStateStore.ThreadRow(
            id: "thread-1",
            displayTitle: displayTitle,
            preview: preview,
            cwd: cwd,
            status: status,
            listedStatus: status,
            updatedAt: Date(timeIntervalSince1970: 100),
            isWatched: true,
            pendingRequestKind: pendingRequestKind,
            pendingRequestReason: pendingRequestReason,
            activeTurnID: activeTurnID,
            lastTerminalActivityAt: nil
        )
    }

    private func threadRow(
        status: AppStateStore.ThreadStatus,
        displayTitle: String = "Thread title",
        preview: String = "Preview",
        cwd: String = "/tmp/thread-1",
        pendingRequestKind: AppStateStore.PendingRequestKind? = nil,
        pendingRequestReason: String? = nil,
        activeTurnID: String? = nil
    ) -> AppStateStore.ThreadRow {
        Self.threadRow(
            status: status,
            displayTitle: displayTitle,
            preview: preview,
            cwd: cwd,
            pendingRequestKind: pendingRequestKind,
            pendingRequestReason: pendingRequestReason,
            activeTurnID: activeTurnID
        )
    }
}
