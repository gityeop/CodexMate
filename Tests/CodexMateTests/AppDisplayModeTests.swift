import XCTest
@testable import CodexMate

final class AppDisplayModeTests: XCTestCase {
    func testResolvedDisplayModeMatchesExpectedBehavior() {
        let cases: [(mode: AppDisplayMode, hasHardwareNotch: Bool, expected: AppDisplayMode)] = [
            (.menuBar, false, .menuBar),
            (.notch, true, .notch),
            (.notch, false, .notch),
        ]

        for testCase in cases {
            XCTAssertEqual(
                testCase.mode.resolved(hasHardwareNotch: testCase.hasHardwareNotch),
                testCase.expected
            )
        }
    }
}
