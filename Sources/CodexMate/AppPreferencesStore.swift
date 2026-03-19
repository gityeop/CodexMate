import Combine
import Foundation

@MainActor
final class AppPreferencesStore: ObservableObject {
    static let defaultThreadsPerProjectLimit = 8
    static let threadsPerProjectLimitRange = 1...50

    private enum DefaultsKey {
        static let language = "appLanguage"
        static let attentionNotificationsEnabled = "attentionNotificationsEnabled"
        static let completionNotificationsEnabled = "completionNotificationsEnabled"
        static let failureNotificationsEnabled = "failureNotificationsEnabled"
        static let threadsPerProjectLimit = "threadsPerProjectLimit"
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

    @Published var threadsPerProjectLimit: Int {
        didSet {
            let clampedLimit = Self.clampedThreadsPerProjectLimit(threadsPerProjectLimit)
            guard threadsPerProjectLimit == clampedLimit else {
                threadsPerProjectLimit = clampedLimit
                return
            }

            defaults.set(threadsPerProjectLimit, forKey: DefaultsKey.threadsPerProjectLimit)
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
        if defaults.object(forKey: DefaultsKey.threadsPerProjectLimit) == nil {
            threadsPerProjectLimit = Self.defaultThreadsPerProjectLimit
        } else {
            threadsPerProjectLimit = Self.clampedThreadsPerProjectLimit(
                defaults.integer(forKey: DefaultsKey.threadsPerProjectLimit)
            )
        }
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    private static func clampedThreadsPerProjectLimit(_ limit: Int) -> Int {
        min(max(limit, threadsPerProjectLimitRange.lowerBound), threadsPerProjectLimitRange.upperBound)
    }
}
