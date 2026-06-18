import Combine
import Foundation

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("AppPreferencesStore.languageDidChange")
    static let appDisplayModeDidChange = Notification.Name("AppPreferencesStore.displayModeDidChange")
}

@MainActor
final class AppPreferencesStore: ObservableObject {
    static let defaultProjectLimit = 5
    static let projectLimitRange = 1...ProjectMenuShortcut.maxCount
    static let defaultThreadsPerProjectLimit = 8
    static let threadsPerProjectLimitRange = 1...50
    static let defaultThreadListSectionLimit = 20
    static let threadListSectionLimitRange = 1...100

    private enum DefaultsKey {
        static let language = "appLanguage"
        static let displayMode = "displayMode"
        static let attentionNotificationsEnabled = "attentionNotificationsEnabled"
        static let completionNotificationsEnabled = "completionNotificationsEnabled"
        static let failureNotificationsEnabled = "failureNotificationsEnabled"
        static let notchStatusContentEnabled = "notchStatusContentEnabled"
        static let projectLimit = "projectLimit"
        static let threadsPerProjectLimit = "threadsPerProjectLimit"
        static let threadListViewMode = "threadListViewMode"
        static let threadListSectionLimit = "threadListSectionLimit"
        static let pinnedThreadIDs = "pinnedThreadIDs"
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: DefaultsKey.language)
            guard language != oldValue else {
                return
            }

            NotificationCenter.default.post(name: .appLanguageDidChange, object: self)
        }
    }

    @Published var displayMode: AppDisplayMode {
        didSet {
            defaults.set(displayMode.rawValue, forKey: DefaultsKey.displayMode)
            NotificationCenter.default.post(name: .appDisplayModeDidChange, object: self)
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

    @Published var notchStatusContentEnabled: Bool {
        didSet {
            defaults.set(notchStatusContentEnabled, forKey: DefaultsKey.notchStatusContentEnabled)
        }
    }

    @Published var projectLimit: Int {
        didSet {
            let clampedLimit = Self.clampedProjectLimit(projectLimit)
            guard projectLimit == clampedLimit else {
                projectLimit = clampedLimit
                return
            }

            defaults.set(projectLimit, forKey: DefaultsKey.projectLimit)
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

    @Published var threadListViewMode: ThreadListViewMode {
        didSet {
            defaults.set(threadListViewMode.rawValue, forKey: DefaultsKey.threadListViewMode)
        }
    }

    @Published var threadListSectionLimit: Int {
        didSet {
            let clampedLimit = Self.clampedThreadListSectionLimit(threadListSectionLimit)
            guard threadListSectionLimit == clampedLimit else {
                threadListSectionLimit = clampedLimit
                return
            }

            defaults.set(threadListSectionLimit, forKey: DefaultsKey.threadListSectionLimit)
        }
    }

    @Published private(set) var pinnedThreadIDs: Set<String> {
        didSet {
            defaults.set(pinnedThreadIDs.sorted(), forKey: DefaultsKey.pinnedThreadIDs)
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage.fromStoredValue(defaults.string(forKey: DefaultsKey.language))
        displayMode = AppDisplayMode.fromStoredValue(defaults.string(forKey: DefaultsKey.displayMode))
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
        if defaults.object(forKey: DefaultsKey.notchStatusContentEnabled) == nil {
            notchStatusContentEnabled = true
        } else {
            notchStatusContentEnabled = defaults.bool(forKey: DefaultsKey.notchStatusContentEnabled)
        }
        if defaults.object(forKey: DefaultsKey.projectLimit) == nil {
            projectLimit = Self.defaultProjectLimit
        } else {
            projectLimit = Self.clampedProjectLimit(defaults.integer(forKey: DefaultsKey.projectLimit))
        }
        if defaults.object(forKey: DefaultsKey.threadsPerProjectLimit) == nil {
            threadsPerProjectLimit = Self.defaultThreadsPerProjectLimit
        } else {
            threadsPerProjectLimit = Self.clampedThreadsPerProjectLimit(
                defaults.integer(forKey: DefaultsKey.threadsPerProjectLimit)
            )
        }
        threadListViewMode = ThreadListViewMode.fromStoredValue(
            defaults.string(forKey: DefaultsKey.threadListViewMode)
        )
        if defaults.object(forKey: DefaultsKey.threadListSectionLimit) == nil {
            threadListSectionLimit = Self.defaultThreadListSectionLimit
        } else {
            threadListSectionLimit = Self.clampedThreadListSectionLimit(
                defaults.integer(forKey: DefaultsKey.threadListSectionLimit)
            )
        }
        pinnedThreadIDs = Self.loadPinnedThreadIDs(defaults: defaults)
    }

    var locale: Locale {
        Locale(identifier: language.localeIdentifier)
    }

    func isThreadPinned(threadID: String) -> Bool {
        pinnedThreadIDs.contains(threadID)
    }

    @discardableResult
    func togglePinnedThread(threadID: String) -> Bool {
        if pinnedThreadIDs.contains(threadID) {
            pinnedThreadIDs.remove(threadID)
            return false
        }

        pinnedThreadIDs.insert(threadID)
        return true
    }

    private static func clampedProjectLimit(_ limit: Int) -> Int {
        min(max(limit, projectLimitRange.lowerBound), projectLimitRange.upperBound)
    }

    private static func clampedThreadsPerProjectLimit(_ limit: Int) -> Int {
        min(max(limit, threadsPerProjectLimitRange.lowerBound), threadsPerProjectLimitRange.upperBound)
    }

    private static func clampedThreadListSectionLimit(_ limit: Int) -> Int {
        min(max(limit, threadListSectionLimitRange.lowerBound), threadListSectionLimitRange.upperBound)
    }

    private static func loadPinnedThreadIDs(defaults: UserDefaults) -> Set<String> {
        guard defaults.object(forKey: DefaultsKey.pinnedThreadIDs) != nil else {
            return []
        }

        guard let storedThreadIDs = defaults.stringArray(forKey: DefaultsKey.pinnedThreadIDs) else {
            preconditionFailure("Invalid stored pinned thread IDs.")
        }

        return Set(storedThreadIDs)
    }
}
