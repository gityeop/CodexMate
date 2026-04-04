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

    func testScrollWheelClearsHoverImmediately() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        view.configure(
            title: "Thread title",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )

        let titleLabel = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first)
        let initialTextColor = try XCTUnwrap(titleLabel.textColor)

        let enterEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .mouseMoved,
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
        view.mouseEntered(with: enterEvent)

        XCTAssertNotEqual(titleLabel.textColor, initialTextColor)

        let cgScrollEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: 10,
                wheel2: 0,
                wheel3: 0
            )
        )
        let scrollEvent = try XCTUnwrap(NSEvent(cgEvent: cgScrollEvent))
        view.scrollWheel(with: scrollEvent)

        XCTAssertEqual(titleLabel.textColor, initialTextColor)
    }

    func testHitTestReturnsNilOutsideBounds() {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        view.configure(
            title: "Thread title",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )

        XCTAssertNil(view.hitTest(NSPoint(x: -4, y: 11)))
        XCTAssertNil(view.hitTest(NSPoint(x: 281, y: 11)))
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 24)))
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


    func testIndicatorTextDisplaysEmojiWithoutImage() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        view.configure(
            title: "Thread title",
            indicatorText: "💬",
            indicatorImage: nil,
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )
        view.layoutSubtreeIfNeeded()

        let labels = view.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains(where: { $0.stringValue == "💬" && !$0.isHidden }))

        let imageView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertTrue(imageView.isHidden)
    }

    func testIndicatorImageTakesPrecedenceOverTextFallback() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        let indicatorImage = NSImage(size: NSSize(width: 8, height: 8))
        view.configure(
            title: "Thread title",
            indicatorText: "💬",
            indicatorImage: indicatorImage,
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )

        let imageView = try XCTUnwrap(view.subviews.compactMap { $0 as? NSImageView }.first)
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        let indicatorLabel = try XCTUnwrap(labels.first(where: { $0.stringValue == "💬" }))

        XCTAssertFalse(imageView.isHidden)
        XCTAssertTrue(indicatorLabel.isHidden)
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

    func testSecondaryTextPinsToTrailingEdgeWithoutOverlappingTitle() throws {
        let view = ThreadDropdownMenuRowView(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        view.configure(
            title: "A very long thread title that should truncate first",
            secondaryText: "2일 전",
            indicatorImage: NSImage(size: NSSize(width: 8, height: 8)),
            indentationLevel: 0,
            isExpandable: false,
            isExpanded: false,
            onOpen: {},
            onToggle: nil
        )
        view.layoutSubtreeIfNeeded()

        let labels = view.subviews.compactMap { $0 as? NSTextField }
        let titleLabel = try XCTUnwrap(labels.first(where: { $0.stringValue.hasPrefix("A very long") }))
        let secondaryLabel = try XCTUnwrap(labels.first(where: { $0.stringValue == "2일 전" }))

        XCTAssertLessThan(titleLabel.frame.maxX, secondaryLabel.frame.minX)
        XCTAssertEqual(secondaryLabel.frame.maxX, view.bounds.maxX - 8, accuracy: 0.5)
    }
}
