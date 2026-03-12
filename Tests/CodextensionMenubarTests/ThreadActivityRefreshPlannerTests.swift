import XCTest
@testable import CodextensionMenubar

final class ThreadActivityRefreshPlannerTests: XCTestCase {
    func testShouldRefreshThreadsWhenConversationActivityIncludesUnknownThread() {
        let shouldRefresh = ThreadActivityRefreshPlanner.shouldRefreshThreads(
            recentThreadIDs: ["thread-1", "thread-2"],
            latestViewedAtByThreadID: [
                "thread-2": Date(timeIntervalSince1970: 100),
                "thread-3": Date(timeIntervalSince1970: 200),
            ]
        )

        XCTAssertTrue(shouldRefresh)
    }

    func testShouldNotRefreshThreadsWhenConversationActivityOnlyIncludesKnownThreads() {
        let shouldRefresh = ThreadActivityRefreshPlanner.shouldRefreshThreads(
            recentThreadIDs: ["thread-1", "thread-2"],
            latestViewedAtByThreadID: [
                "thread-1": Date(timeIntervalSince1970: 100),
                "thread-2": Date(timeIntervalSince1970: 200),
            ]
        )

        XCTAssertFalse(shouldRefresh)
    }
}
