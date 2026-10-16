import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class ProjectGraphWindowTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testClosingStopsGitRefreshAndReopeningReusesWindow() throws {
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        application.setActivationPolicy(.accessory)
        let store = ProjectGraphStore()
        let controller = ProjectGraphWindowController(store: store, openThread: { _ in }, openSettings: {})
        let window = try XCTUnwrap(controller.window)
        defer {
            window.close()
            application.setActivationPolicy(originalActivationPolicy)
        }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(application.activationPolicy(), .accessory)
        controller.showWindow(nil)
        XCTAssertEqual(application.activationPolicy(), .regular)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible)
        XCTAssertTrue(window.styleMask.contains(.resizable))

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(store.isVisible)
        XCTAssertEqual(application.activationPolicy(), .accessory)

        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible)
        XCTAssertEqual(application.activationPolicy(), .regular)
    }
}
