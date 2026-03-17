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
    }

    var language: AppLanguage {
        preferences.language
    }

    var languageOptions: [AppLanguage] {
        AppLanguage.allCases
    }

    var shortcutName: KeyboardShortcuts.Name {
        .toggleMenuBarDropdown
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

    func setLanguage(_ language: AppLanguage) {
        preferences.language = language
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
}
