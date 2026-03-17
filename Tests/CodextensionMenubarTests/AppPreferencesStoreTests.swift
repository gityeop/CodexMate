import XCTest
@testable import CodextensionMenubar

@MainActor
final class AppPreferencesStoreTests: XCTestCase {
    func testDefaultsUseSystemLanguageAndEnableNotifications() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.language, .system)
        XCTAssertTrue(store.attentionNotificationsEnabled)
        XCTAssertTrue(store.completionNotificationsEnabled)
        XCTAssertTrue(store.failureNotificationsEnabled)
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

        let reloaded = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .korean)
        XCTAssertFalse(reloaded.attentionNotificationsEnabled)
        XCTAssertFalse(reloaded.completionNotificationsEnabled)
        XCTAssertFalse(reloaded.failureNotificationsEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
