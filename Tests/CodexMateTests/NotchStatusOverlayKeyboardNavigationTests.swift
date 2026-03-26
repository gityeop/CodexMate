import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class NotchStatusOverlayKeyboardNavigationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testMenuOpenSelectsFirstEnabledRow() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 1")
    }

    func testArrowNavigationSkipsHeadersSeparatorsAndDisabledRows() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 125, characters: "↓")
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 2")

        try sendKeyEvent(to: view, keyCode: 126, characters: "↑")
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 1")
    }

    func testArrowNavigationAcceptsFunctionModifier() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 125, characters: "↓", modifierFlags: [.function])
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 2")

        try sendKeyEvent(to: view, keyCode: 126, characters: "↑", modifierFlags: [.function])
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 1")
    }

    func testOptionArrowNavigationMovesByProject() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeSectionedMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 125, characters: "↓", modifierFlags: [.option])
        XCTAssertEqual(try selectedRowTitle(in: view), "Project B Thread 1")

        try sendKeyEvent(to: view, keyCode: 126, characters: "↑", modifierFlags: [.option])
        XCTAssertEqual(try selectedRowTitle(in: view), "Project A Thread 1")
    }

    func testArrowNavigationScrollsSelectedRowIntoView() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeScrollableMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(firstScrollView(in: view))
        let initialOriginY = scrollView.contentView.bounds.origin.y

        for _ in 0..<9 {
            try sendKeyEvent(to: view, keyCode: 125, characters: "↓")
        }

        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 10")
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, initialOriginY)
    }

    func testSelectingFirstItemInSectionKeepsHeaderVisible() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 96))
        view.setMenuItems(makeSectionedMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        for _ in 0..<2 {
            try sendKeyEvent(to: view, keyCode: 125, characters: "↓")
        }

        XCTAssertEqual(try selectedRowTitle(in: view), "Project B Thread 1")

        let scrollView = try XCTUnwrap(firstScrollView(in: view))
        let headerLabel = try XCTUnwrap(firstLabel(in: view, stringValue: "Project B | 스레드 2개"))
        let headerFrame = headerLabel.convert(headerLabel.bounds, to: scrollView.documentView)
        XCTAssertTrue(scrollView.contentView.bounds.intersects(headerFrame))
    }

    func testManualScrollClearsKeyboardSelectionAndDoesNotRestoreOnRebuild() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeStableIdentifierMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 125, characters: "↓")
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 2")

        let selectedRow = try XCTUnwrap(allRowViews(in: view).first(where: { $0.isHighlighted }))
        selectedRow.scrollWheel(with: try makeScrollEvent(deltaY: 10))

        XCTAssertFalse(allRowViews(in: view).contains(where: { $0.isHighlighted }))

        view.setMenuItems(makeStableIdentifierMenuItems())
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(allRowViews(in: view).contains(where: { $0.isHighlighted }))
    }

    func testUpArrowAfterManualScrollUsesVisibleBottomContext() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 96))
        view.setMenuItems(makeBottomActionMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        let selectedRow = try XCTUnwrap(allRowViews(in: view).first(where: { $0.isHighlighted }))
        selectedRow.scrollWheel(with: try makeScrollEvent(deltaY: 10))
        XCTAssertFalse(allRowViews(in: view).contains(where: { $0.isHighlighted }))

        let scrollView = try XCTUnwrap(firstScrollView(in: view))
        let documentView = try XCTUnwrap(scrollView.documentView)
        let bottomOriginY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomOriginY))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        try sendKeyEvent(to: view, keyCode: 126, characters: "↑")
        XCTAssertEqual(try selectedRowTitle(in: view), "Settings")
    }

    func testMenuRowWidthsStayStableWhileExpansionProgressChanges() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeScrollableMenuItems())
        view.menuExpansionProgress = 0.35
        view.layoutSubtreeIfNeeded()

        let partiallyExpandedWidths = allRowViews(in: view).map(\.frame.width)

        view.menuExpansionProgress = 1
        view.layoutSubtreeIfNeeded()

        let fullyExpandedWidths = allRowViews(in: view).map(\.frame.width)
        XCTAssertEqual(partiallyExpandedWidths.count, fullyExpandedWidths.count)

        for (partialWidth, expandedWidth) in zip(partiallyExpandedWidths, fullyExpandedWidths) {
            XCTAssertEqual(partialWidth, expandedWidth, accuracy: 0.5)
        }
    }

    func testReturnActivatesSelectedRow() throws {
        let expectation = expectation(description: "selected row activates")
        var activationCount = 0

        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems([
            .header("Recent threads"),
            .item(primaryText: "Thread 1", onSelect: {
                activationCount += 1
                expectation.fulfill()
            }),
            .separator(),
            .item(primaryText: "Thread 2", onSelect: {
                XCTFail("Unexpected activation")
            }),
        ])
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 36, characters: "\r")

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(activationCount, 1)
    }

    func testControllerKeyboardRoutingHandlesArrowNavigationAndReturnWithoutFirstResponder() throws {
        let expectation = expectation(description: "controller-selected row activates")
        var activationCount = 0

        let controller = NotchStatusOverlayController()
        controller.setMenuItems([
            .header("Recent threads"),
            .item(primaryText: "Thread 1", onSelect: {
                activationCount += 1
                expectation.fulfill()
            }),
            .separator(),
            .item(primaryText: "Thread 2", onSelect: {
                XCTFail("Unexpected activation")
            }),
        ])

        XCTAssertTrue(controller.handleKeyboardEvent(try makeKeyEvent(keyCode: 125, characters: "↓")))
        XCTAssertTrue(controller.handleKeyboardEvent(try makeKeyEvent(keyCode: 36, characters: "\r")))

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(activationCount, 1)
    }

    func testSelectionSurvivesMenuRebuildWithStableIdentifiers() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems(makeStableIdentifierMenuItems())
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        try sendKeyEvent(to: view, keyCode: 125, characters: "↓")
        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 2")

        view.setMenuItems(makeStableIdentifierMenuItems())
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(try selectedRowTitle(in: view), "Thread 2")
    }

    func testHoveredRowDoesNotVisuallyOverrideKeyboardSelection() throws {
        let view = NotchStatusOverlayView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        view.setMenuItems([
            .item(primaryText: "Thread 1", onSelect: {}),
            .item(primaryText: "Settings", onSelect: {}),
            .item(primaryText: "Quit", onSelect: {}),
        ])
        view.menuExpansionProgress = 1
        view.prepareForMenuOpen()
        view.layoutSubtreeIfNeeded()

        let rows = allRowViews(in: view)
        let hoveredRow = try XCTUnwrap(rows.last)
        hoveredRow.mouseEntered(with: try makeMouseEvent(type: .mouseMoved))

        let hoveredLabel = try XCTUnwrap(
            hoveredRow.subviews.compactMap { $0 as? NSTextField }.first
        )
        XCTAssertEqual(hoveredLabel.textColor, .labelColor)
    }

    private func makeMenuItems() -> [NotchStatusOverlayMenuEntry] {
        [
            .header("Recent threads"),
            .item(primaryText: "Thread 1", onSelect: {}),
            .separator(),
            .item(primaryText: "Disabled thread", isEnabled: false, onSelect: {}),
            .item(primaryText: "Thread 2", onSelect: {}),
        ]
    }

    private func makeStableIdentifierMenuItems() -> [NotchStatusOverlayMenuEntry] {
        [
            .header("Recent threads"),
            .item(primaryText: "Thread 1", identifier: "thread-1", onSelect: {}),
            .separator(),
            .item(primaryText: "Disabled thread", identifier: "disabled-thread", isEnabled: false, onSelect: {}),
            .item(primaryText: "Thread 2", identifier: "thread-2", onSelect: {}),
        ]
    }

    private func makeScrollableMenuItems() -> [NotchStatusOverlayMenuEntry] {
        [
            .header("Recent threads"),
            .item(primaryText: "Thread 1", onSelect: {}),
            .separator(),
            .item(primaryText: "Disabled thread", isEnabled: false, onSelect: {}),
            .item(primaryText: "Thread 2", onSelect: {}),
            .item(primaryText: "Thread 3", onSelect: {}),
            .item(primaryText: "Thread 4", onSelect: {}),
            .item(primaryText: "Thread 5", onSelect: {}),
            .item(primaryText: "Thread 6", onSelect: {}),
            .item(primaryText: "Thread 7", onSelect: {}),
            .item(primaryText: "Thread 8", onSelect: {}),
            .item(primaryText: "Thread 9", onSelect: {}),
            .item(primaryText: "Thread 10", onSelect: {}),
        ]
    }

    private func makeSectionedMenuItems() -> [NotchStatusOverlayMenuEntry] {
        [
            .header("Project A | 스레드 2개"),
            .item(primaryText: "Project A Thread 1", projectIndex: 0, onSelect: {}),
            .item(primaryText: "Project A Thread 2", projectIndex: 0, onSelect: {}),
            .separator(),
            .header("Project B | 스레드 2개"),
            .item(primaryText: "Project B Thread 1", projectIndex: 1, onSelect: {}),
            .item(primaryText: "Project B Thread 2", projectIndex: 1, onSelect: {}),
        ]
    }

    private func makeBottomActionMenuItems() -> [NotchStatusOverlayMenuEntry] {
        [
            .header("Recent threads"),
            .item(primaryText: "Thread 1", onSelect: {}),
            .item(primaryText: "Thread 2", onSelect: {}),
            .item(primaryText: "Thread 3", onSelect: {}),
            .item(primaryText: "Thread 4", onSelect: {}),
            .item(primaryText: "Thread 5", onSelect: {}),
            .separator(),
            .item(primaryText: "Settings", onSelect: {}),
            .item(primaryText: "Quit", onSelect: {}),
        ]
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func makeScrollEvent(deltaY: Int32) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: deltaY,
                wheel2: 0,
                wheel3: 0
            )
        )

        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    private func sendKeyEvent(
        to view: NSView,
        keyCode: UInt16,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )

        view.keyDown(with: event)
    }

    private func makeMouseEvent(type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0
            )
        )
    }

    private func selectedRowTitle(in view: NSView) throws -> String {
        let selectedRow = try XCTUnwrap(
            allRowViews(in: view).first(where: { $0.isHighlighted })
        )
        let titleLabel = try XCTUnwrap(
            selectedRow.subviews.compactMap { $0 as? NSTextField }.first
        )
        return titleLabel.stringValue
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        allSubviews(in: view).compactMap { $0 as? NSScrollView }.first
    }

    private func firstLabel(in view: NSView, stringValue: String) -> NSTextField? {
        allSubviews(in: view)
            .compactMap { $0 as? NSTextField }
            .first(where: { $0.stringValue == stringValue })
    }

    private func allRowViews(in view: NSView) -> [ThreadDropdownMenuRowView] {
        allSubviews(in: view).compactMap { $0 as? ThreadDropdownMenuRowView }
    }

    private func allSubviews(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(in: $0) }
    }
}
