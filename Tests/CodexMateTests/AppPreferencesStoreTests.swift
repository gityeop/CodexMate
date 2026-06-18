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
        XCTAssertTrue(store.notchStatusContentEnabled)
        XCTAssertEqual(store.projectLimit, AppPreferencesStore.defaultProjectLimit)
        XCTAssertEqual(store.threadsPerProjectLimit, AppPreferencesStore.defaultThreadsPerProjectLimit)
        XCTAssertEqual(store.threadListViewMode, .projects)
        XCTAssertEqual(store.threadListSectionLimit, AppPreferencesStore.defaultThreadListSectionLimit)
        XCTAssertTrue(store.pinnedThreadIDs.isEmpty)
    }

    func testPreferenceChangesPersistToUserDefaults() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        store.language = .korean
        store.displayMode = .menuBar
        store.attentionNotificationsEnabled = false
        store.completionNotificationsEnabled = false
        store.failureNotificationsEnabled = false
        store.notchStatusContentEnabled = false
        store.projectLimit = 7
        store.threadsPerProjectLimit = 12
        store.threadListViewMode = .status
        store.threadListSectionLimit = 24
        store.togglePinnedThread(threadID: "thread-a")
        store.togglePinnedThread(threadID: "thread-b")

        let reloaded = AppPreferencesStore(defaults: defaults)
        XCTAssertEqual(reloaded.language, .korean)
        XCTAssertEqual(reloaded.displayMode, .menuBar)
        XCTAssertFalse(reloaded.attentionNotificationsEnabled)
        XCTAssertFalse(reloaded.completionNotificationsEnabled)
        XCTAssertFalse(reloaded.failureNotificationsEnabled)
        XCTAssertFalse(reloaded.notchStatusContentEnabled)
        XCTAssertEqual(reloaded.projectLimit, 7)
        XCTAssertEqual(reloaded.threadsPerProjectLimit, 12)
        XCTAssertEqual(reloaded.threadListViewMode, .status)
        XCTAssertEqual(reloaded.threadListSectionLimit, 24)
        XCTAssertEqual(reloaded.pinnedThreadIDs, Set(["thread-a", "thread-b"]))
    }

    func testTogglePinnedThreadPersistsUpdatedPinnedSet() {
        let defaults = makeDefaults()
        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertTrue(store.togglePinnedThread(threadID: "thread-a"))
        XCTAssertTrue(store.isThreadPinned(threadID: "thread-a"))
        XCTAssertFalse(store.togglePinnedThread(threadID: "thread-a"))
        XCTAssertFalse(store.isThreadPinned(threadID: "thread-a"))

        let reloaded = AppPreferencesStore(defaults: defaults)
        XCTAssertFalse(reloaded.isThreadPinned(threadID: "thread-a"))
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

    func testThreadListSectionLimitClampsOutOfRangeValues() {
        let defaults = makeDefaults()
        defaults.set(0, forKey: "threadListSectionLimit")

        let store = AppPreferencesStore(defaults: defaults)

        XCTAssertEqual(
            store.threadListSectionLimit,
            AppPreferencesStore.threadListSectionLimitRange.lowerBound
        )

        store.threadListSectionLimit = 999

        XCTAssertEqual(
            store.threadListSectionLimit,
            AppPreferencesStore.threadListSectionLimitRange.upperBound
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
