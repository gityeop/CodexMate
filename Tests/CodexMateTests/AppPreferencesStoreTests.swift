import XCTest
@testable import CodexMate

@MainActor
private final class LanguageChangeObserver: NSObject {
    let defaults: UserDefaults
    private(set) var notificationCount = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    @objc
    func handleLanguageChange(_ notification: Notification) {
        notificationCount += 1
        XCTAssertEqual(defaults.string(forKey: "appLanguage"), AppLanguage.korean.rawValue)
    }
}

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    func testDefaultsUseSystemLanguageAndEnableNotifications() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.language, .system)
        XCTAssertEqual(store.displayMode, .notch)
        XCTAssertTrue(store.attentionNotificationsEnabled)
        XCTAssertTrue(store.completionNotificationsEnabled)
        XCTAssertTrue(store.failureNotificationsEnabled)
        XCTAssertEqual(store.projectLimit, AppPreferencesStore.defaultProjectLimit)
        XCTAssertEqual(store.threadsPerProjectLimit, AppPreferencesStore.defaultThreadsPerProjectLimit)
    }

    func testInvalidStoredLanguageFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("unknown-language", forKey: "appLanguage")

        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.language, .system)
    }

    func testPreferenceChangesPersistToUserDefaults() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        store.language = .korean
        store.displayMode = .menuBar
        store.attentionNotificationsEnabled = false
        store.completionNotificationsEnabled = false
        store.failureNotificationsEnabled = false
        store.projectLimit = 7
        store.threadsPerProjectLimit = 12

        let reloaded = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .korean)
        XCTAssertEqual(reloaded.displayMode, .menuBar)
        XCTAssertFalse(reloaded.attentionNotificationsEnabled)
        XCTAssertFalse(reloaded.completionNotificationsEnabled)
        XCTAssertFalse(reloaded.failureNotificationsEnabled)
        XCTAssertEqual(reloaded.projectLimit, 7)
        XCTAssertEqual(reloaded.threadsPerProjectLimit, 12)
    }

    func testLanguageChangePostsNotificationOnceAfterPersisting() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)
        let observer = LanguageChangeObserver(defaults: defaults)
        NotificationCenter.default.addObserver(
            observer,
            selector: #selector(LanguageChangeObserver.handleLanguageChange(_:)),
            name: .appLanguageDidChange,
            object: store
        )
        defer {
            NotificationCenter.default.removeObserver(observer)
        }

        store.language = .korean

        XCTAssertEqual(observer.notificationCount, 1)
    }

    func testInvalidStoredDisplayModeFallsBackToNotch() {
        let defaults = makeDefaults()
        defaults.set("invalid-mode", forKey: "displayMode")

        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.displayMode, .notch)
    }

    func testThreadsPerProjectLimitClampsOutOfRangeValues() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: "threadsPerProjectLimit")

        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(
            store.threadsPerProjectLimit,
            AppPreferencesStore.threadsPerProjectLimitRange.lowerBound
        )

        store.threadsPerProjectLimit = 999

        XCTAssertEqual(
            store.threadsPerProjectLimit,
            AppPreferencesStore.threadsPerProjectLimitRange.upperBound
        )
    }

    func testProjectLimitClampsOutOfRangeValues() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: "projectLimit")

        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(
            store.projectLimit,
            AppPreferencesStore.projectLimitRange.lowerBound
        )

        store.projectLimit = 999

        XCTAssertEqual(
            store.projectLimit,
            AppPreferencesStore.projectLimitRange.upperBound
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
