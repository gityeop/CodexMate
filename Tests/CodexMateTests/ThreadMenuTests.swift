import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class ThreadMenuTests: XCTestCase {
    func testReturnShortcutOpensHighlightedThread() throws {
        let event = try makeKeyEvent(
            keyCode: 36,
            characters: "\r"
        )

        XCTAssertEqual(
            ThreadMenu.shortcutAction(for: event),
            .openHighlightedThread
        )
    }

    func testEnterShortcutOpensHighlightedThread() throws {
        let event = try makeKeyEvent(
            keyCode: 76,
            modifierFlags: [.numericPad],
            characters: "\u{3}"
        )

        XCTAssertEqual(
            ThreadMenu.shortcutAction(for: event),
            .openHighlightedThread
        )
    }

    func testCommandNumberShortcutMapsToProjectIndex() throws {
        let event = try makeKeyEvent(
            keyCode: 20,
            modifierFlags: [.command],
            characters: "3"
        )

        XCTAssertEqual(
            ThreadMenu.shortcutAction(for: event),
            .openProjectThread(2)
        )
    }

    func testCommandNumberShortcutRejectsExtraModifiers() throws {
        let event = try makeKeyEvent(
            keyCode: 18,
            modifierFlags: [.command, .shift],
            characters: "!",
            charactersIgnoringModifiers: "1"
        )

        XCTAssertNil(ThreadMenu.shortcutAction(for: event))
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
