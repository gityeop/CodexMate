import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testVisibilityCallbackTracksShowAndClose() throws {
        let controller = makeController()
        var visibilityChanges: [Bool] = []
        controller.onVisibilityChanged = { visibilityChanges.append($0) }

        controller.showWindow(nil)
        XCTAssertTrue(controller.isWindowVisible)

        controller.window?.close()
        XCTAssertFalse(controller.isWindowVisible)
        XCTAssertEqual(visibilityChanges, [true, false])
    }

    private func makeController() -> SettingsWindowController {
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

        return SettingsWindowController(viewModel: viewModel)
    }
}
