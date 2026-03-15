import XCTest
@testable import CodextensionMenubar

final class RefreshSchedulingPolicyTests: XCTestCase {
    func testIdlePolicyUsesSlowThreadListRefresh() {
        let policy = RefreshSchedulingPolicy.current(
            isMenuOpen: false,
            overallStatus: .idle,
            hasRecentThreads: true
        )

        XCTAssertEqual(policy.desktopActivityInterval, 5)
        XCTAssertEqual(policy.threadListInterval, 60)
        XCTAssertEqual(policy.timerInterval, 5)
    }

    func testRunningPolicyKeepsFastDesktopPollingButSlowerThreadListRefresh() {
        let policy = RefreshSchedulingPolicy.current(
            isMenuOpen: false,
            overallStatus: .running,
            hasRecentThreads: true
        )

        XCTAssertEqual(policy.desktopActivityInterval, 1)
        XCTAssertEqual(policy.threadListInterval, 15)
    }

    func testMenuOpenPolicyRefreshesThreadListMoreFrequently() {
        let policy = RefreshSchedulingPolicy.current(
            isMenuOpen: true,
            overallStatus: .idle,
            hasRecentThreads: true
        )

        XCTAssertEqual(policy.desktopActivityInterval, 1)
        XCTAssertEqual(policy.threadListInterval, 5)
    }

    func testEmptyRecentThreadListRefreshesMoreFrequentlyUntilRecovered() {
        let policy = RefreshSchedulingPolicy.current(
            isMenuOpen: false,
            overallStatus: .idle,
            hasRecentThreads: false
        )

        XCTAssertEqual(policy.desktopActivityInterval, 5)
        XCTAssertEqual(policy.threadListInterval, 5)
        XCTAssertEqual(policy.timerInterval, 5)
    }

    func testShouldRefreshUsesConfiguredIntervals() {
        let policy = RefreshSchedulingPolicy.current(
            isMenuOpen: false,
            overallStatus: .idle,
            hasRecentThreads: true
        )
        let now = Date(timeIntervalSince1970: 120)

        XCTAssertTrue(policy.shouldRefreshDesktopActivity(now: now, lastRequestedAt: nil))
        XCTAssertFalse(
            policy.shouldRefreshDesktopActivity(
                now: now,
                lastRequestedAt: Date(timeIntervalSince1970: 116)
            )
        )
        XCTAssertTrue(
            policy.shouldRefreshThreadList(
                now: now,
                lastRequestedAt: Date(timeIntervalSince1970: 59)
            )
        )
    }
}
