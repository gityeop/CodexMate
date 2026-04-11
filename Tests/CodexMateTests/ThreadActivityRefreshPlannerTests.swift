import XCTest
@testable import CodexMate

final class ThreadActivityRefreshPlannerTests: XCTestCase {
    func testShouldRefreshThreadsWhenStateSnapshotIncludesUnknownAttentionSignals() {
        let recentActivityRefresh = ThreadActivityRefreshPlanner.shouldRefreshThreads(
            recentThreadIDs: ["thread-1", "thread-2"],
            latestViewedAtByThreadID: [:],
            recentActivityThreadIDs: ["thread-3"]
        )
        let approvalRefresh = ThreadActivityRefreshPlanner.shouldRefreshThreads(
            recentThreadIDs: ["thread-1", "thread-2"],
            latestViewedAtByThreadID: [:],
            attentionThreadIDs: ["thread-3"]
        )

        XCTAssertTrue(recentActivityRefresh)
        XCTAssertTrue(approvalRefresh)
    }

    func testShouldRefreshThreadsForRecentlyViewedUnknownThread() {
        XCTAssertTrue(
            ThreadActivityRefreshPlanner.shouldRefreshThreads(
                recentThreadIDs: ["thread-1", "thread-2"],
                latestViewedAtByThreadID: [
                    "thread-3": Date(timeIntervalSince1970: 205),
                ],
                now: Date(timeIntervalSince1970: 210),
                discoveryLookbackInterval: 30
            )
        )
    }

    func testShouldNotRefreshThreadsForStaleOrAlreadyTrackedDiscoverySignals() {
        let cases: [([String: Date], Bool)] = [
            ([
                "thread-2": Date(timeIntervalSince1970: 100),
                "thread-3": Date(timeIntervalSince1970: 100),
            ], false),
            ([
                "thread-1": Date(timeIntervalSince1970: 100),
                "thread-2": Date(timeIntervalSince1970: 200),
            ], false),
            ([
                "thread-3": Date(timeIntervalSince1970: 100),
            ], false),
        ]

        for (latestViewedAtByThreadID, expected) in cases {
            XCTAssertEqual(
                ThreadActivityRefreshPlanner.shouldRefreshThreads(
                    recentThreadIDs: ["thread-1", "thread-2"],
                    latestViewedAtByThreadID: latestViewedAtByThreadID,
                    now: Date(timeIntervalSince1970: 210),
                    discoveryLookbackInterval: 30
                ),
                expected
            )
        }
    }
}
