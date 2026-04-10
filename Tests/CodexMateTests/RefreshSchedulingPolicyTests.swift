import XCTest
@testable import CodexMate

final class RefreshSchedulingPolicyTests: XCTestCase {
    func testCurrentPolicyMatchesExpectedIntervalsForEachMode() {
        let cases: [
            (
                isMenuOpen: Bool,
                overallStatus: AppStateStore.OverallStatus,
                hasRecentThreads: Bool,
                desktopActivityInterval: TimeInterval,
                threadListInterval: TimeInterval,
                timerInterval: TimeInterval
            )
        ] = [
            (false, .idle, true, 5, 60, 5),
            (false, .running, true, 1, 15, 1),
            (true, .idle, true, 1, 5, 1),
            (false, .idle, false, 5, 5, 5),
        ]

        for testCase in cases {
            let policy = RefreshSchedulingPolicy.current(
                isMenuOpen: testCase.isMenuOpen,
                overallStatus: testCase.overallStatus,
                hasRecentThreads: testCase.hasRecentThreads
            )

            XCTAssertEqual(policy.desktopActivityInterval, testCase.desktopActivityInterval)
            XCTAssertEqual(policy.threadListInterval, testCase.threadListInterval)
            XCTAssertEqual(policy.timerInterval, testCase.timerInterval)
        }
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
