import AppKit
import Carbon.HIToolbox
import XCTest
@testable import CodexMate

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
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
