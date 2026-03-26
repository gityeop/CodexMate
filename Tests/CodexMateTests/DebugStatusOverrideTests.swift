import XCTest
@testable import CodexMate

final class DebugStatusOverrideTests: XCTestCase {
    func testOverallStatusReadsKnownValues() {
        XCTAssertEqual(
            DebugStatusOverride.overallStatus(from: [DebugStatusOverride.environmentKey: "failed"]),
            .failed
        )
        XCTAssertEqual(
            DebugStatusOverride.overallStatus(from: [DebugStatusOverride.environmentKey: "waiting_for_user"]),
            .waitingForUser
        )
        XCTAssertEqual(
            DebugStatusOverride.overallStatus(from: [DebugStatusOverride.environmentKey: "running"]),
            .running
        )
    }

    func testOverallStatusIgnoresUnknownValue() {
        XCTAssertNil(
            DebugStatusOverride.overallStatus(from: [DebugStatusOverride.environmentKey: "not-a-status"])
        )
    }
}
