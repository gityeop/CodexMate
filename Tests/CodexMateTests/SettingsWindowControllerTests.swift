import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import XCTest
@testable import CodexMate

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testClearButtonFocusesRecorderAndShowsRecordingState() throws {
        let control = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 300, height: MateUI.controlHeight))
        let window = NSWindow(contentRect: control.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = control
        control.recorder.placeholderLabel = "Click and press shortcut"
        control.recorder.recordingLabel = "Press a shortcut now"
        control.recorder.shortcut = KeyboardShortcuts.Shortcut(.c, modifiers: [.command, .option])
        var changes: [KeyboardShortcuts.Shortcut?] = []
        control.onChange = {
            changes.append($0)
            control.recorder.shortcut = $0
        }
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.makeFirstResponder(nil)

        control.clearButton.performClick(nil)

        XCTAssertEqual(changes.count, 1)
        XCTAssertNil(changes[0])
        XCTAssertTrue(window.firstResponder === control.recorder)
        XCTAssertEqual(control.recorder.stringValue, "Press a shortcut now")
        XCTAssertEqual(control.recorder.layer?.borderWidth, 1)
        let focusedBorder = control.recorder.layer?.borderColor
        XCTAssertFalse(control.clearButton.isEnabled)

        control.recorder.keyDown(with: try makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_N), modifierFlags: [.control, .option], characters: "n"
        ))

        XCTAssertEqual(changes.last!, KeyboardShortcuts.Shortcut(.n, modifiers: [.control, .option]))
        XCTAssertFalse(window.firstResponder === control.recorder)
        XCTAssertEqual(control.recorder.layer?.borderWidth, 1)
        XCTAssertNotEqual(control.recorder.layer?.borderColor, focusedBorder)
        XCTAssertTrue(control.clearButton.isEnabled)
    }

    func testDeleteKeyKeepsRecorderFocusedForReplacementShortcut() throws {
        let control = ShortcutRecorderControl(frame: NSRect(x: 0, y: 0, width: 300, height: MateUI.controlHeight))
        let window = NSWindow(contentRect: control.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = control
        control.recorder.recordingLabel = "Press a shortcut now"
        control.recorder.shortcut = KeyboardShortcuts.Shortcut(.c, modifiers: [.command])
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.makeFirstResponder(control.recorder)

        control.recorder.keyDown(with: try makeKeyEvent(keyCode: UInt16(kVK_Delete), characters: "\u{7f}"))

        XCTAssertNil(control.recorder.shortcut)
        XCTAssertTrue(window.firstResponder === control.recorder)
        XCTAssertEqual(control.recorder.layer?.borderWidth, 1)
    }

    func testVisibilityCallbackTracksShowAndClose() throws {
        let controller = makeController().controller
        var visibilityChanges: [Bool] = []
        controller.onVisibilityChanged = { visibilityChanges.append($0) }

        controller.showWindow(nil)
        XCTAssertTrue(controller.isWindowVisible)

        controller.window?.close()
        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertEqual(visibilityChanges, [true, false])
    }

    func testWindowTitleUpdatesImmediatelyWhenLanguageChanges() throws {
        let dependencies = makeController()
        let controller = dependencies.controller
        dependencies.preferences.language = .english
        controller.showWindow(nil)

        XCTAssertEqual(controller.window?.title, "Settings")

        dependencies.preferences.language = .korean

        XCTAssertEqual(controller.window?.title, "설정")
    }

    func testCommandWClosesWindow() throws {
        let controller = makeController().controller
        var visibilityChanges: [Bool] = []
        controller.onVisibilityChanged = { visibilityChanges.append($0) }

        controller.showWindow(nil)
        XCTAssertTrue(controller.isWindowVisible)

        let event = try makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_W),
            modifierFlags: [.command],
            characters: "w"
        )
        XCTAssertTrue(controller.window?.performKeyEquivalent(with: event) == true)

        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertEqual(visibilityChanges, [true, false])
    }

    func testSettingsPickersHaveFlatMenusAndUpdateTheirBinding() throws {
        let dependencies = makeController()
        dependencies.preferences.language = .english
        dependencies.controller.showWindow(nil)
        let window = try XCTUnwrap(dependencies.controller.window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        func popups(in view: NSView) -> [NSPopUpButton] {
            if let popup = view as? NSPopUpButton { return [popup] }
            return view.subviews.flatMap { popups(in: $0) }
        }
        let controls = popups(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(controls.count, 3)
        for control in controls {
            XCTAssertGreaterThan(control.numberOfItems, 1)
            XCTAssertTrue(control.itemArray.allSatisfy { $0.submenu == nil })
        }
        let language = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "Language" })
        language.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(language.action), to: language.target, from: language))
        XCTAssertEqual(dependencies.preferences.language, .korean)
    }

    private func makeController() -> (controller: SettingsWindowController, preferences: AppPreferencesStore) {
        let defaultsSuiteName = "SettingsWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let updaterSnapshot = UpdaterSnapshot(
            status: .unavailable,
            automaticallyChecksForUpdates: false,
            canCheckForUpdates: false
        )
        let preferences = AppPreferencesStore(defaults: defaults)
        let viewModel = SettingsViewModel(
            preferences: preferences,
            strings: AppStrings.shared,
            launchAtLoginService: LaunchAtLoginService(isAppBundle: false),
            updaterService: UpdaterService(
                initialSnapshot: updaterSnapshot,
                refreshHandler: { updaterSnapshot },
                setAutomaticallyChecksHandler: { _ in updaterSnapshot },
                checkForUpdatesHandler: {}
            )
        )

        return (SettingsWindowController(viewModel: viewModel), preferences)
    }

    private func makeKeyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String
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
}
