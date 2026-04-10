import XCTest
@testable import CodexMate

final class ForegroundRefreshThrottleTests: XCTestCase {
    func testShouldTriggerRespectsMinimumIntervalAcrossCalls() {
        var throttle = ForegroundRefreshThrottle(minimumInterval: 1)
        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 100.5)))
        XCTAssertTrue(throttle.shouldTrigger(now: Date(timeIntervalSince1970: 101)))
    }
}
