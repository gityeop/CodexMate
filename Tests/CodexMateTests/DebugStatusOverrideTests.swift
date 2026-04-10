import XCTest
@testable import CodexMate

final class DebugStatusOverrideTests: XCTestCase {
    func testOverallStatusParsesKnownValuesAndRejectsUnknownOnes() {
        let cases: [(rawValue: String, expected: AppStateStore.OverallStatus?)] = [
            ("failed", .failed),
            ("waiting_for_user", .waitingForUser),
            ("running", .running),
            ("not-a-status", nil),
        ]

        for testCase in cases {
            XCTAssertEqual(
                DebugStatusOverride.overallStatus(
                    from: [DebugStatusOverride.environmentKey: testCase.rawValue]
                ),
                testCase.expected
            )
        }
    }
}
