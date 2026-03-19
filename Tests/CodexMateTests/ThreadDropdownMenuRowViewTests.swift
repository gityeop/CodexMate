import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class ThreadDropdownMenuRowViewTests: XCTestCase {
    func testMouseUpOpensThreadWithoutTogglingDisclosure() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        var openCount = 0
        var toggleCount = 0

        view.configure(
            title: "Thread title",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: true,
            isExpanded: false,
            onOpen: {
                openCount += 1
            },
            onToggle: {
                toggleCount += 1
            }
        )

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: 80, y: 11),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )

        view.mouseUp(with: event)

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(toggleCount, 0)
    }

    func testDisclosureButtonTogglesWithoutOpeningThread() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        var openCount = 0
        var toggleCount = 0

        view.configure(
            title: "Thread title",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: true,
            isExpanded: false,
            onOpen: {
                openCount += 1
            },
            onToggle: {
                toggleCount += 1
            }
        )
        view.layoutSubtreeIfNeeded()

        let disclosureButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)
        let disclosureCenter = NSPoint(x: disclosureButton.frame.midX, y: disclosureButton.frame.midY)

        XCTAssertTrue(view.hitTest(disclosureCenter) === disclosureButton)

        disclosureButton.performClick(nil)

        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(toggleCount, 1)
    }
}
