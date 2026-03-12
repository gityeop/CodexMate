import XCTest
@testable import CodextensionMenubar

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
        activeTurnID: String? = nil
    ) -> AppStateStore.ThreadRow {
        AppStateStore.ThreadRow(
            id: "thread-1",
            displayTitle: "Thread title",
            preview: "Preview",
            cwd: "/tmp/thread-1",
            status: status,
            listedStatus: status,
            updatedAt: Date(timeIntervalSince1970: 100),
            isWatched: true,
            activeTurnID: activeTurnID,
            lastTerminalActivityAt: nil
        )
    }

    private func threadRow(
        status: AppStateStore.ThreadStatus,
        activeTurnID: String? = nil
    ) -> AppStateStore.ThreadRow {
        Self.threadRow(status: status, activeTurnID: activeTurnID)
    }
}
