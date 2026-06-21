import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class ThreadMenuTests: XCTestCase {
    func testOpenHighlightedItemShortcutsCoverReturnAndEnter() throws {
        let cases: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (36, [], "\r"),
            (76, [.numericPad], "\u{3}"),
        ]

        for (keyCode, modifierFlags, characters) in cases {
            let event = try makeKeyEvent(
                keyCode: keyCode,
                modifierFlags: modifierFlags,
                characters: characters
            )

            XCTAssertEqual(
                ThreadMenu.shortcutAction(for: event),
                .openHighlightedItem
            )
        }
    }

    func testKeyboardShortcutsMapToExpectedActions() throws {
        let cases: [(event: NSEvent, expected: ThreadMenuKeyboardShortcutAction?)] = [
            (
                try makeKeyEvent(
                    keyCode: 20,
                    modifierFlags: [.command],
                    characters: "3"
                ),
                .openProjectThread(2)
            ),
            (
                try makeKeyEvent(
                    keyCode: 29,
                    modifierFlags: [.command],
                    characters: "0"
                ),
                .openProjectThread(9)
            ),
            (
                try makeKeyEvent(
                    keyCode: 18,
                    modifierFlags: [.command, .shift],
                    characters: "!",
                    charactersIgnoringModifiers: "1"
                ),
                nil
            ),
            (
                try makeKeyEvent(
                    keyCode: 35,
                    modifierFlags: [.command],
                    characters: "p"
                ),
                .togglePinnedThread
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.option],
                    characters: "↓"
                ),
                .movePrimarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.option],
                    characters: "↑"
                ),
                .movePrimarySelection(-1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.command],
                    characters: "↓"
                ),
                .moveBoundarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.command],
                    characters: "↑"
                ),
                .moveBoundarySelection(-1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.option, .function, .numericPad],
                    characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!)
                ),
                .movePrimarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.command, .function, .numericPad],
                    characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
                ),
                .moveBoundarySelection(-1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.option, .capsLock, .function, .numericPad],
                    characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!)
                ),
                .movePrimarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.command, .capsLock, .function, .numericPad],
                    characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
                ),
                .moveBoundarySelection(-1)
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            XCTAssertEqual(
                ThreadMenu.shortcutAction(for: testCase.event),
                testCase.expected,
                "case \(index)"
            )
        }
    }

    func testMenuBarModifiedArrowShortcutsUsePhysicalModifiers() throws {
        let cases: [(
            event: NSEvent,
            physicalModifiers: Set<AppDelegate.MenuBarPhysicalModifier>,
            expected: ThreadMenuKeyboardShortcutAction?
        )] = [
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.command, .function, .numericPad],
                    characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!)
                ),
                [.option],
                .movePrimarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.command, .capsLock, .function, .numericPad],
                    characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
                ),
                [.option],
                .movePrimarySelection(-1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.option],
                    characters: "↓"
                ),
                [.command],
                .moveBoundarySelection(1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 126,
                    modifierFlags: [.option, .capsLock, .function, .numericPad],
                    characters: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                    charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!)
                ),
                [.command],
                .moveBoundarySelection(-1)
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.command, .option],
                    characters: "↓"
                ),
                [.command, .option],
                nil
            ),
            (
                try makeKeyEvent(
                    keyCode: 125,
                    modifierFlags: [.option],
                    characters: "↓"
                ),
                [],
                nil
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            XCTAssertEqual(
                AppDelegate.menuBarModifiedArrowShortcutAction(
                    for: testCase.event,
                    physicalModifiers: testCase.physicalModifiers
                ),
                testCase.expected,
                "case \(index)"
            )
        }
    }

    func testMenuBarBoundarySelectionUsesFirstAndLastSelectableMenuItems() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Project A", action: nil, keyEquivalent: ""))
        menu.addItem(makeSelectableItem(title: "Project A Thread 1"))
        menu.addItem(makeSelectableItem(title: "Project A Thread 2"))
        menu.addItem(.separator())
        menu.addItem(makeSelectableItem(title: "Settings"))
        menu.addItem(makeSelectableItem(title: "Quit"))

        let hiddenShortcut = makeSelectableItem(title: "Hidden Shortcut")
        hiddenShortcut.isHidden = true
        menu.addItem(hiddenShortcut)

        XCTAssertEqual(
            AppDelegate.menuBarBoundarySelectionItem(in: menu, delta: -1)?.title,
            "Project A Thread 1"
        )
        XCTAssertEqual(
            AppDelegate.menuBarBoundarySelectionItem(in: menu, delta: 1)?.title,
            "Quit"
        )
    }

    func testPerformKeyEquivalentDoesNotConsumePinnedToggleShortcut() throws {
        let menu = ThreadMenu()
        var handledActions: [ThreadMenuKeyboardShortcutAction] = []
        menu.onKeyboardShortcut = { action in
            handledActions.append(action)
            return true
        }

        let event = try makeKeyEvent(
            keyCode: 35,
            modifierFlags: [.command],
            characters: "p"
        )

        XCTAssertFalse(menu.performKeyEquivalent(with: event))
        XCTAssertTrue(handledActions.isEmpty)
    }

    func testPerformKeyEquivalentDoesNotDispatchModifiedArrowNavigation() throws {
        let cases: [NSEvent] = [
            try makeKeyEvent(
                keyCode: 125,
                modifierFlags: [.option],
                characters: "↓"
            ),
            try makeKeyEvent(
                keyCode: 126,
                modifierFlags: [.option],
                characters: "↑"
            ),
            try makeKeyEvent(
                keyCode: 125,
                modifierFlags: [.command],
                characters: "↓"
            ),
            try makeKeyEvent(
                keyCode: 126,
                modifierFlags: [.command],
                characters: "↑"
            ),
        ]

        for event in cases {
            let menu = ThreadMenu()
            var handledActions: [ThreadMenuKeyboardShortcutAction] = []
            menu.onKeyboardShortcut = { action in
                handledActions.append(action)
                return true
            }

            XCTAssertFalse(menu.performKeyEquivalent(with: event))
            XCTAssertTrue(handledActions.isEmpty)
        }
    }

    func testMenuBarPhysicalModifierActionCanDifferFromThreadMenuLogicalAction() throws {
        let event = try makeKeyEvent(
            keyCode: 125,
            modifierFlags: [.command, .function, .numericPad],
            characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        )

        XCTAssertEqual(ThreadMenu.shortcutAction(for: event), .moveBoundarySelection(1))
        XCTAssertEqual(
            AppDelegate.menuBarModifiedArrowShortcutAction(for: event, physicalModifiers: [.option]),
            .movePrimarySelection(1)
        )
    }

    func testPerformKeyEquivalentDispatchesReturnActivationShortcut() throws {
        let menu = ThreadMenu()
        var handledActions: [ThreadMenuKeyboardShortcutAction] = []
        menu.onKeyboardShortcut = { action in
            handledActions.append(action)
            return true
        }

        let event = try makeKeyEvent(
            keyCode: 36,
            characters: "\r"
        )

        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(handledActions, [.openHighlightedItem])
    }

    func testMenuSupportsProgrammaticHighlightSelector() {
        let menu = ThreadMenu()

        XCTAssertTrue(menu.responds(to: NSSelectorFromString("highlightItem:")))
    }

    func testThreadIDCopyShortcutOnlyUsesOptionMouseActivation() throws {
        let optionReturn = try makeKeyEvent(
            keyCode: 36,
            modifierFlags: [.option],
            characters: "\r"
        )
        let optionClick = try makeMouseEvent(
            type: .leftMouseDown,
            modifierFlags: [.option]
        )
        let normalClick = try makeMouseEvent(
            type: .leftMouseDown,
            modifierFlags: []
        )

        XCTAssertFalse(AppDelegate.shouldCopyThreadIDForOpenEvent(optionReturn))
        XCTAssertTrue(AppDelegate.shouldCopyThreadIDForOpenEvent(optionClick))
        XCTAssertFalse(AppDelegate.shouldCopyThreadIDForOpenEvent(normalClick))
    }

    func testProjectShortcutKeyEquivalentsExpandThroughZero() {
        XCTAssertEqual(ProjectMenuShortcut.maxCount, 10)
        XCTAssertEqual(ProjectMenuShortcut.keyEquivalent(for: 0), "1")
        XCTAssertEqual(ProjectMenuShortcut.keyEquivalent(for: 8), "9")
        XCTAssertEqual(ProjectMenuShortcut.keyEquivalent(for: 9), "0")
        XCTAssertNil(ProjectMenuShortcut.keyEquivalent(for: 10))
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String,
        charactersIgnoringModifiers: String? = nil
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
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func makeMouseEvent(
        type: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private func makeSelectableItem(title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: #selector(NSObject.description), keyEquivalent: "")
    }
}
