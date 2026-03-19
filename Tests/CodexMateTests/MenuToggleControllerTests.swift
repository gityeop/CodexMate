import XCTest
@testable import CodexMate

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
        XCTAssertTrue(controller.isMenuPresented)

        controller.toggleMenu()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(controller.isMenuPresented)
    }

    func testToggleTwiceClosesMenuBeforeDelegateCallbacksArrive() {
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
        controller.toggleMenu()

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(controller.isMenuPresented)
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
