import Combine
import Foundation

@MainActor
final class AppPreferencesStore: ObservableObject {
    private enum DefaultsKey {
        static let language = "appLanguage"
        static let attentionNotificationsEnabled = "attentionNotificationsEnabled"
        static let completionNotificationsEnabled = "completionNotificationsEnabled"
        static let failureNotificationsEnabled = "failureNotificationsEnabled"
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: DefaultsKey.language)
        }
    }

    @Published var attentionNotificationsEnabled: Bool {
        didSet {
            defaults.set(attentionNotificationsEnabled, forKey: DefaultsKey.attentionNotificationsEnabled)
        }
    }

    @Published var completionNotificationsEnabled: Bool {
        didSet {
            defaults.set(completionNotificationsEnabled, forKey: DefaultsKey.completionNotificationsEnabled)
        }
    }

    @Published var failureNotificationsEnabled: Bool {
        didSet {
            defaults.set(failureNotificationsEnabled, forKey: DefaultsKey.failureNotificationsEnabled)
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage.fromStoredValue(defaults.string(forKey: DefaultsKey.language))
        if defaults.object(forKey: DefaultsKey.attentionNotificationsEnabled) == nil {
            attentionNotificationsEnabled = true
        } else {
            attentionNotificationsEnabled = defaults.bool(forKey: DefaultsKey.attentionNotificationsEnabled)
        }
        if defaults.object(forKey: DefaultsKey.completionNotificationsEnabled) == nil {
            completionNotificationsEnabled = true
        } else {
            completionNotificationsEnabled = defaults.bool(forKey: DefaultsKey.completionNotificationsEnabled)
        }
        if defaults.object(forKey: DefaultsKey.failureNotificationsEnabled) == nil {
            failureNotificationsEnabled = true
        } else {
            failureNotificationsEnabled = defaults.bool(forKey: DefaultsKey.failureNotificationsEnabled)
        }
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }
}
