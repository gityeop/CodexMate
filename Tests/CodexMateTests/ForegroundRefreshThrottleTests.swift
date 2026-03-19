import XCTest
@testable import CodexMate

final class ForegroundRefreshThrottleTests: XCTestCase {
    func testShouldTriggerAllowsFirstForegroundRefresh() {
        var throttle = ForegroundRefreshThrottle(minimumInterval: 1)

        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100)))
    }

    func testShouldTriggerCoalescesForegroundRefreshesWithinMinimumInterval() {
        var throttle = ForegroundRefreshThrottle(minimumInterval: 1)

        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100.5)))
    }

    func testShouldTriggerAllowsForegroundRefreshAfterMinimumInterval() {
        var throttle = ForegroundRefreshThrottle(minimumInterval: 1)

        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 101)))
    }
}
