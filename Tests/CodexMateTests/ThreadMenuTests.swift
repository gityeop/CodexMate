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
        ]

        for (index, testCase) in cases.enumerated() {
            XCTAssertEqual(
                ThreadMenu.shortcutAction(for: testCase.event),
                testCase.expected,
                "case \(index)"
            )
        }
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
}
