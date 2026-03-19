import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    func testClosingLastWindowDoesNotTerminateApp() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
