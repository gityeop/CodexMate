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
        let store = ProjectGraphStore()
        let controller = ProjectGraphWindowController(store: store, openThread: { _ in }, openSettings: {})
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        controller.showWindow(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible)
        XCTAssertTrue(window.styleMask.contains(.resizable))

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(store.isVisible)

        controller.showWindow(nil)
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(store.isVisible)
    }
}
