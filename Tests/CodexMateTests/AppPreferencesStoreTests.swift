import XCTest
@testable import CodexMate

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    func testDefaultsUseSystemLanguageAndEnableNotifications() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.language, .system)
        XCTAssertTrue(store.attentionNotificationsEnabled)
        XCTAssertTrue(store.completionNotificationsEnabled)
        XCTAssertTrue(store.failureNotificationsEnabled)
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
        store.attentionNotificationsEnabled = false
        store.completionNotificationsEnabled = false
        store.failureNotificationsEnabled = false
        store.threadsPerProjectLimit = 12

        let reloaded = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .korean)
        XCTAssertFalse(reloaded.attentionNotificationsEnabled)
        XCTAssertFalse(reloaded.completionNotificationsEnabled)
        XCTAssertFalse(reloaded.failureNotificationsEnabled)
        XCTAssertEqual(reloaded.threadsPerProjectLimit, 12)
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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
