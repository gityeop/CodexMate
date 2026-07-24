import AppKit
import XCTest
@testable import CodexMate

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testClosingLastWindowDoesNotTerminateApp() {
        let delegate = AppDelegate()

        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testOpenMenuThreadRefreshPreservesWeeklyUsageItem() {
        let menu = NSMenu()
        let weeklyUsageItem = NSMenuItem(title: "Weekly usage", action: nil, keyEquivalent: "")
        weeklyUsageItem.view = WeeklyUsageIndicatorView(
            remainingPercent: 87,
            resetsAt: nil,
            language: .english
        )
        let oldThreadItem = NSMenuItem(title: "Old thread", action: nil, keyEquivalent: "")
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.representedObject = "settings"
        let quitItem = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "")
        [weeklyUsageItem, oldThreadItem, .separator(), settingsItem, quitItem].forEach(menu.addItem)

        let updatedThreadItem = NSMenuItem(title: "Updated thread", action: nil, keyEquivalent: "")
        AppDelegate.replaceOpenMenuBarThreadItems(
            in: menu,
            weeklyUsageItem: weeklyUsageItem,
            settingsIdentifier: "settings",
            visibleItems: [updatedThreadItem]
        )

        XCTAssertTrue(menu.items.first === weeklyUsageItem)
        XCTAssertTrue(menu.items.first?.view is WeeklyUsageIndicatorView)
        XCTAssertTrue(menu.items[1] === updatedThreadItem)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertTrue(menu.items[3] === settingsItem)
        XCTAssertTrue(menu.items[4] === quitItem)
        XCTAssertFalse(menu.items.contains(where: { $0 === oldThreadItem }))
    }
}
