import XCTest
@testable import CodexMate

@MainActor
final class SettingsViewModelTests: XCTestCase {
    func testProjectThreadListModeShowsProjectSettingsOnly() {
        let dependencies = makeViewModel()
        dependencies.preferences.threadListViewMode = .projects

        XCTAssertTrue(dependencies.viewModel.showsProjectThreadListSettings)
        XCTAssertFalse(dependencies.viewModel.showsSectionThreadListSettings)
    }

    func testRecentAndStatusThreadListModesShowSectionSettingsOnly() {
        let dependencies = makeViewModel()

        dependencies.preferences.threadListViewMode = .recent

        XCTAssertFalse(dependencies.viewModel.showsProjectThreadListSettings)
        XCTAssertTrue(dependencies.viewModel.showsSectionThreadListSettings)

        dependencies.preferences.threadListViewMode = .status

        XCTAssertFalse(dependencies.viewModel.showsProjectThreadListSettings)
        XCTAssertTrue(dependencies.viewModel.showsSectionThreadListSettings)
    }

    func testNotchStatusContentSettingFollowsDisplayMode() {
        let dependencies = makeViewModel()

        dependencies.preferences.displayMode = .menuBar

        XCTAssertFalse(dependencies.viewModel.showsNotchStatusContentSetting)

        dependencies.preferences.displayMode = .notch

        XCTAssertTrue(dependencies.viewModel.showsNotchStatusContentSetting)
    }

    private func makeViewModel() -> (viewModel: SettingsViewModel, preferences: AppPreferencesStore) {
        let defaultsSuiteName = "SettingsViewModelTests.\(UUID().uuidString)"
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

        return (viewModel, preferences)
    }
}
