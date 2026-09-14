import AppKit
import XCTest
@testable import CodexMate

final class WeeklyUsageTests: XCTestCase {
    func testUsesOnlyDefaultWeeklyWindow() throws {
        let response = try decodeResponse(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 3,
                  "windowDurationMins": 10080,
                  "resetsAt": 1785258369
                },
                "secondary": null
              },
              "rateLimitsByLimitId": {
                "additional-model": {
                  "primary": {
                    "usedPercent": 0,
                    "windowDurationMins": 10080
                  }
                }
              }
            }
            """
        )
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resetsAt = Date(timeIntervalSince1970: 1_785_258_369)

        let reading = try WeeklyUsageParser.reading(from: response, readAt: readAt)

        XCTAssertEqual(
            reading,
            WeeklyUsageReading(
                remainingPercent: 97,
                resetsAt: resetsAt,
                readAt: readAt
            )
        )
    }

    func testFindsWeeklyWindowInEitherDefaultSlot() throws {
        let response = try decodeResponse(
            """
            {
              "rateLimits": {
                "primary": {
                  "usedPercent": 10,
                  "windowDurationMins": 300
                },
                "secondary": {
                  "usedPercent": 35,
                  "windowDurationMins": 10080
                }
              }
            }
            """
        )

        let reading = try WeeklyUsageParser.reading(from: response)

        XCTAssertEqual(reading.remainingPercent, 65)
    }

    func testClampsServerPercentBeforeComputingRemainingValue() throws {
        let overusedResponse = try decodeResponse(
            #"{"rateLimits":{"primary":{"usedPercent":140,"windowDurationMins":10080}}}"#
        )
        let negativeResponse = try decodeResponse(
            #"{"rateLimits":{"primary":{"usedPercent":-12,"windowDurationMins":10080}}}"#
        )

        XCTAssertEqual(
            try WeeklyUsageParser.reading(from: overusedResponse).remainingPercent,
            0
        )
        XCTAssertEqual(
            try WeeklyUsageParser.reading(from: negativeResponse).remainingPercent,
            100
        )
    }

    func testMissingWeeklyWindowReturnsExplicitError() throws {
        let response = try decodeResponse(
            #"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}"#
        )

        XCTAssertThrowsError(try WeeklyUsageParser.reading(from: response)) { error in
            XCTAssertEqual(error as? WeeklyUsageError, .weeklyWindowUnavailable)
        }
    }

    private func decodeResponse(_ json: String) throws -> AccountRateLimitsResponse {
        try JSONDecoder().decode(AccountRateLimitsResponse.self, from: Data(json.utf8))
    }
}

@MainActor
final class WeeklyUsageIndicatorViewTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try HeadlessAppKitTestSupport.skipIfNeeded()
    }

    func testDisplaysLocalizedWeeklyUsageAndResetTime() {
        let resetsAt = Date(timeIntervalSince1970: 1_785_258_369)
        let timeZone = try! XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let view = WeeklyUsageIndicatorView(
            remainingPercent: 97,
            resetsAt: resetsAt,
            errorMessage: nil,
            language: .korean,
            timeZone: timeZone
        )

        XCTAssertEqual(view.titleText, "주간 사용량")
        XCTAssertEqual(view.valueText, "97% 남음")
        XCTAssertTrue(view.detailText?.hasPrefix("초기화: ") == true)
        XCTAssertTrue(view.accessibilityText.contains("97% 남음"))
        XCTAssertEqual(view.accessibilityLabel(), view.accessibilityText)
    }

    func testLoadingPresentationDoesNotInventAUsageValue() {
        let view = WeeklyUsageIndicatorView(
            remainingPercent: nil,
            resetsAt: nil,
            errorMessage: nil,
            language: .english
        )

        XCTAssertEqual(view.titleText, "Weekly usage")
        XCTAssertEqual(view.valueText, "Loading…")
        XCTAssertNil(view.detailText)
        XCTAssertEqual(view.accessibilityText, "Weekly usage, Loading…")
    }

    func testFailurePresentationLooksLikeLoading() {
        let errorMessage = "Codex RPC error -32000: authentication required"
        let view = WeeklyUsageIndicatorView(
            remainingPercent: nil,
            resetsAt: nil,
            errorMessage: errorMessage,
            language: .korean
        )

        XCTAssertEqual(view.valueText, "불러오는 중…")
        XCTAssertNil(view.detailText)
        XCTAssertEqual(view.accessibilityText, "주간 사용량, 불러오는 중…")
    }

    func testUsesNativeStatusColorsAtRemainingThresholds() {
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 100), .systemGreen)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 50), .systemGreen)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 49), .systemOrange)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 20), .systemOrange)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 19), .systemRed)
    }

    func testMenuKeepsUsageVisibleWhileScrollingToLastItem() throws {
        let view = WeeklyUsageIndicatorView(
            remainingPercent: 81,
            resetsAt: nil,
            pinsToMenu: true,
            language: .english
        )
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        let menu = NSMenu()
        let usageItem = NSMenuItem()
        usageItem.view = view
        menu.addItem(usageItem)
        for index in 0..<100 {
            menu.addItem(withTitle: "Thread \(index)", action: nil, keyEquivalent: "")
        }

        var inspected = false
        let inspectMenu: @MainActor @Sendable () -> Void = {
            defer { menu.cancelTracking() }
            inspected = true
            guard let scrollView = view.enclosingScrollView,
                  let table = scrollView.documentView as? NSTableView,
                  let header = view.menuHeaderView else {
                XCTFail("Weekly usage header was not attached to the native menu")
                return
            }
            let initialFrame = header.convert(header.bounds, to: nil)
            XCTAssertEqual(initialFrame.height, 56)
            XCTAssertNotNil(header.window)
            XCTAssertFalse(
                initialFrame.intersects(scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)),
                "Usage and thread viewport overlap; contentInsets=\(scrollView.contentInsets)"
            )
            table.scrollRowToVisible(table.numberOfRows - 1)
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
            XCTAssertTrue(view.menuHeaderView === header)
            XCTAssertEqual(header.convert(header.bounds, to: nil), initialFrame)
            XCTAssertEqual(header.visibleRect.height, 56)
            XCTAssertFalse(
                header.convert(header.bounds, to: nil).intersects(
                    scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
                ),
                "Usage and thread viewport overlap after scrolling"
            )
            XCTAssertGreaterThan(scrollView.contentView.bounds.height, 0)
            XCTAssertTrue(scrollView.documentVisibleRect.contains(table.rect(ofRow: table.numberOfRows - 1)))
            scrollView.tile()
            XCTAssertFalse(
                header.convert(header.bounds, to: nil).intersects(
                    scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
                ),
                "Native menu relayout must preserve the separate thread viewport"
            )
            XCTAssertTrue(header.subviews.contains {
                ($0 as? WeeklyUsageIndicatorView)?.valueText == view.valueText
            })

            let updatedView = WeeklyUsageIndicatorView(
                remainingPercent: 64,
                resetsAt: nil,
                pinsToMenu: true,
                language: .english
            )
            updatedView.frame = NSRect(origin: .zero, size: updatedView.intrinsicContentSize)
            updatedView.updatePinnedMenuHeader(replacing: view)
            usageItem.view = updatedView
            menu.update()
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertTrue(updatedView.menuHeaderView?.subviews.contains {
                ($0 as? WeeklyUsageIndicatorView)?.remainingPercent == 64
            } == true)
            XCTAssertFalse(
                updatedView.menuHeaderView!.convert(header.bounds, to: nil).intersects(
                    scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
                ),
                "Refreshing usage must preserve the separate thread viewport"
            )

            table.scrollRowToVisible(0)
            scrollView.layoutSubtreeIfNeeded()
            XCTAssertEqual(updatedView.menuHeaderView?.convert(header.bounds, to: nil), initialFrame)
        }
        let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated { inspectMenu() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        let screen = try XCTUnwrap(NSScreen.main)
        menu.popUp(positioning: nil, at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 20), in: nil)
        timer.invalidate()
        XCTAssertTrue(inspected)
    }

    func testMenuScrollArrowsDoNotMoveUsageHeader() throws {
        let view = WeeklyUsageIndicatorView(
            remainingPercent: 80,
            resetsAt: nil,
            pinsToMenu: true,
            language: .korean
        )
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let usageItem = NSMenuItem()
        usageItem.view = view
        menu.addItem(usageItem)
        for index in 0..<100 {
            let item = NSMenuItem(title: "Thread \(index)", action: #selector(selectTestThread(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        var phase = 0
        var initialHeaderFrame = NSRect.zero
        var menuTable: NSTableView?
        let inspectMenu: @MainActor @Sendable () -> Void = {
            guard phase < 3 else { return }
            if phase == 0 {
                menuTable = view.enclosingScrollView?.documentView as? NSTableView
            }
            guard let table = menuTable,
                  let header = view.menuHeaderView else {
                XCTFail("Missing native menu header")
                menu.cancelTracking()
                return
            }
            let headerFrame = header.convert(header.bounds, to: nil)
            if let body = table.enclosingScrollView?.superview {
                XCTAssertFalse(
                    headerFrame.intersects(body.convert(body.bounds, to: nil)),
                    "Scroll arrows and threads must stay below weekly usage"
                )
            }
            if let indicator = header.subviews.first as? WeeklyUsageIndicatorView,
               let label = indicator.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "80% 남음" }) {
                XCTAssertTrue(
                    header.visibleRect.contains(label.convert(label.bounds, to: header)),
                    "Remaining usage text is clipped: label=\(label.convert(label.bounds, to: header)), visible=\(header.visibleRect)"
                )
            } else {
                XCTFail("Missing remaining usage label")
            }
            let frameFromTop = NSRect(x: headerFrame.minX, y: header.window!.frame.height - headerFrame.maxY, width: headerFrame.width, height: headerFrame.height)
            if phase == 0 {
                initialHeaderFrame = frameFromTop
                menu.perform(NSSelectorFromString("highlightItem:"), with: menu.items.last)
                view.revealMenuItem(menu.items.last)
            } else {
                XCTAssertEqual(frameFromTop, initialHeaderFrame, "Scroll arrows must not move weekly usage relative to the menu top")
                if phase == 1 {
                    XCTAssertTrue(table.visibleRect.contains(table.rect(ofRow: table.numberOfRows - 1)), "Last item must remain fully visible after keyboard navigation")
                    menu.perform(NSSelectorFromString("highlightItem:"), with: menu.items[1])
                    view.revealMenuItem(menu.items[1])
                } else {
                    menu.cancelTracking()
                }
            }
            phase += 1
        }
        let screen = try XCTUnwrap(NSScreen.main)
        for _ in 0..<2 {
            phase = 0
            let timer = Timer(timeInterval: 0.15, repeats: true) { _ in
                MainActor.assumeIsolated { inspectMenu() }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            menu.popUp(positioning: nil, at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 20), in: nil)
            timer.invalidate()
            XCTAssertEqual(phase, 3)
        }
    }

    @objc private func selectTestThread(_ sender: NSMenuItem) {}
}
