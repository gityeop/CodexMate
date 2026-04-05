import XCTest
@testable import CodexMate

final class AppDisplayModeTests: XCTestCase {
    func testMenuBarResolvesToMenuBarWithoutHardwareNotch() {
        XCTAssertEqual(AppDisplayMode.menuBar.resolved(hasHardwareNotch: false), .menuBar)
    }

    func testNotchResolvesToNotchWithHardwareNotch() {
        XCTAssertEqual(AppDisplayMode.notch.resolved(hasHardwareNotch: true), .notch)
    }

    func testNotchRemainsNotchWithoutHardwareNotch() {
        XCTAssertEqual(AppDisplayMode.notch.resolved(hasHardwareNotch: false), .notch)
    }
}
