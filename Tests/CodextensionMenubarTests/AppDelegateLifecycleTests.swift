import AppKit
import XCTest
@testable import CodextensionMenubar

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    func testClosingLastWindowDoesNotTerminateApp() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
