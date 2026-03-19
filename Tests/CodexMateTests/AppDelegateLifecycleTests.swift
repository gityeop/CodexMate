import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testClosingLastWindowDoesNotTerminateApp() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
