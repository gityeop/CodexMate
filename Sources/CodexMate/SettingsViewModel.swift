import AppKit
import Combine
import Foundation
import KeyboardShortcuts

@MainActor
final class SettingsViewModel: ObservableObject {
    let preferences: AppPreferencesStore
    let strings: AppStrings
    let launchAtLoginService: LaunchAtLoginService
    let updaterService: UpdaterService

    @Published private(set) var launchAtLoginSnapshot: LaunchAtLoginSnapshot
    @Published private(set) var updaterSnapshot: UpdaterSnapshot

    private var cancellables: Set<AnyCancellable> = []

    init(
        preferences: AppPreferencesStore,
        strings: AppStrings,
        launchAtLoginService: LaunchAtLoginService,
        updaterService: UpdaterService
    ) {
        self.preferences = preferences
        self.strings = strings
        self.launchAtLoginService = launchAtLoginService
        self.updaterService = updaterService
        launchAtLoginSnapshot = launchAtLoginService.snapshot
        updaterSnapshot = updaterService.snapshot

        preferences.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        launchAtLoginService.$snapshot
            .sink { [weak self] snapshot in
                self?.launchAtLoginSnapshot = snapshot
            }
            .store(in: &cancellables)

        updaterService.$snapshot
            .sink { [weak self] snapshot in
                self?.updaterSnapshot = snapshot
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    var language: AppLanguage {
        preferences.language
    }

    var languageOptions: [AppLanguage] {
        AppLanguage.allCases
    }

    var displayModeOptions: [AppDisplayMode] {
        AppDisplayMode.allCases
    }

    var shortcutName: KeyboardShortcuts.Name {
        .toggleMenuBarDropdown
    }

    var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: shortcutName)
    }

    var projectLimitRange: ClosedRange<Int> {
        AppPreferencesStore.projectLimitRange
    }

    var projectLimitLabel: String {
        strings.format(
            "settings.projectLimitLabel",
            language: preferences.language,
            Int64(preferences.projectLimit)
        )
    }

    var threadsPerProjectLimitRange: ClosedRange<Int> {
        AppPreferencesStore.threadsPerProjectLimitRange
    }

    var threadsPerProjectLimitLabel: String {
        strings.format(
            "settings.threadsPerProjectLabel",
            language: preferences.language,
            Int64(preferences.threadsPerProjectLimit)
        )
    }

    func text(_ key: String) -> String {
        strings.text(key, language: preferences.language)
    }

    func label(for language: AppLanguage) -> String {
        switch language {
        case .system:
            return text("settings.language.system")
        case .korean:
            return text("settings.language.korean")
        case .english:
            return text("settings.language.english")
        }
    }

    func label(for displayMode: AppDisplayMode) -> String {
        switch displayMode {
        case .menuBar:
            return text("settings.displayMode.menuBar")
        case .notch:
            return text("settings.displayMode.notch")
        }
    }

    func setLanguage(_ language: AppLanguage) {
        preferences.language = language
    }

    func setDisplayMode(_ displayMode: AppDisplayMode) {
        preferences.displayMode = displayMode
    }

    func setProjectLimit(_ limit: Int) {
        preferences.projectLimit = limit
    }

    func setThreadsPerProjectLimit(_ limit: Int) {
        preferences.threadsPerProjectLimit = limit
    }

    func setLaunchAtLoginEnabled(_ isEnabled: Bool) {
        launchAtLoginService.setEnabled(isEnabled)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        updaterService.setAutomaticallyChecksForUpdates(isEnabled)
    }

    func checkForUpdates() {
        updaterService.checkForUpdates()
    }

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        objectWillChange.send()
    }

    var launchAtLoginMessage: String? {
        switch launchAtLoginSnapshot.status {
        case .unavailable:
            return text("settings.launchAtLogin.unavailable")
        case .requiresApproval:
            return text("settings.launchAtLogin.requiresApproval")
        case let .error(message):
            return strings.format("settings.launchAtLogin.error", language: preferences.language, message)
        case .enabled, .disabled:
            return nil
        }
    }

    var updatesMessage: String? {
        switch updaterSnapshot.status {
        case .unavailable:
            return text("settings.updates.unavailable")
        case let .configurationIssue(message):
            return strings.format("settings.updates.error", language: preferences.language, message)
        case .ready:
            return nil
        }
    }

    var displayModeMessage: String? {
        guard preferences.displayMode == .notch, !NSScreen.screens.contains(where: \.hasCameraHousing) else {
            return nil
        }

        return text("settings.displayMode.notchFallbackHelp")
    }
}
