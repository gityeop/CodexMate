import XCTest
@testable import CodextensionMenubar

final class ThreadSubscriptionPlannerTests: XCTestCase {
    func testMakePlanResumesNewestRecentThreadsUpToTrackedLimit() {
        let recentThreads = [
            threadRow(id: "thread-1", updatedAt: 300),
            threadRow(id: "thread-2", updatedAt: 290),
            threadRow(id: "thread-3", updatedAt: 280),
        ]

        let plan = ThreadSubscriptionPlanner.makePlan(
            recentThreads: recentThreads,
            liveThreadUpdatedAtByID: ["thread-2": Date(timeIntervalSince1970: 290)],
            maxSubscribedThreads: 2
        )

        XCTAssertEqual(plan.targetThreadIDs, ["thread-1", "thread-2"])
        XCTAssertEqual(plan.threadIDsToResume, ["thread-1"])
        XCTAssertEqual(plan.threadIDsToUnsubscribe, [])
    }

    func testMakePlanUnsubscribesThreadsOutsideRecentTrackedWindow() {
        let recentThreads = [
            threadRow(id: "thread-1", updatedAt: 300),
            threadRow(id: "thread-2", updatedAt: 290),
            threadRow(id: "thread-3", updatedAt: 280),
        ]

        let plan = ThreadSubscriptionPlanner.makePlan(
            recentThreads: recentThreads,
            liveThreadUpdatedAtByID: [
                "thread-2": Date(timeIntervalSince1970: 290),
                "thread-4": Date(timeIntervalSince1970: 270),
            ],
            maxSubscribedThreads: 2
        )

        XCTAssertEqual(plan.targetThreadIDs, ["thread-1", "thread-2"])
        XCTAssertEqual(plan.threadIDsToResume, ["thread-1"])
        XCTAssertEqual(plan.threadIDsToUnsubscribe, ["thread-4"])
    }

    private func threadRow(
        id: String,
        updatedAt: TimeInterval,
        status: AppStateStore.ThreadStatus = .idle,
        isWatched: Bool = false
    ) -> AppStateStore.ThreadRow {
        AppStateStore.ThreadRow(
            id: id,
            displayTitle: id,
            preview: id,
            cwd: "/tmp/\(id)",
            status: status,
            listedStatus: status,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isWatched: isWatched,
            activeTurnID: nil,
            lastTerminalActivityAt: nil
        )
    }
}
