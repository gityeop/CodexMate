import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class ThreadDropdownMenuRowViewTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

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

    func testRowsReserveIconSlotEvenWithoutIndicatorImage() throws {
        let plainView = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        plainView.configure(
            title: "Thread title",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )
        plainView.layoutSubtreeIfNeeded()

        let imageView = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        imageView.configure(
            title: "Thread title",
            indicatorImage: NSImage(size: NSSize(width: 8, height: 8)),
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )
        imageView.layoutSubtreeIfNeeded()

        let plainTitleLabel = try XCTUnwrap(plainView.subviews.compactMap { $0 as? NSTextField }.first)
        let imageTitleLabel = try XCTUnwrap(imageView.subviews.compactMap { $0 as? NSTextField }.first)

        XCTAssertEqual(plainTitleLabel.frame.minX, imageTitleLabel.frame.minX)
    }

    func testIndicatorSlotAndTitleStayVerticallyCentered() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        view.configure(
            title: "Thread title",
            indicatorImage: NSImage(size: NSSize(width: 8, height: 8)),
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )
        view.layoutSubtreeIfNeeded()

        let iconView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first)
        let titleLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)

        XCTAssertEqual(iconView.frame.midY, titleLabel.frame.midY)
    }
}
