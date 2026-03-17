import XCTest
@testable import CodextensionMenubar

@MainActor
final class MenuToggleControllerTests: XCTestCase {
    func testToggleOpensThenClosesMenu() {
        var openCount = 0
        var closeCount = 0
        let controller = MenuToggleController(
            openMenu: {
                openCount += 1
            },
            closeMenu: {
                closeCount += 1
            }
        )

        controller.toggleMenu()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 0)

        controller.menuWillOpen()
        controller.toggleMenu()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 1)
    }

    func testMenuStateTracksWillOpenAndDidClose() {
        let controller = MenuToggleController(openMenu: {}, closeMenu: {})

        XCTAssertFalse(controller.isMenuPresented)
        controller.menuWillOpen()
        XCTAssertTrue(controller.isMenuPresented)
        controller.menuDidClose()
        XCTAssertFalse(controller.isMenuPresented)
    }
}
