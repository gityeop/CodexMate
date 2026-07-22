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

    func testFailurePresentationExposesOriginalErrorMessage() {
        let errorMessage = "Codex RPC error -32000: authentication required"
        let view = WeeklyUsageIndicatorView(
            remainingPercent: nil,
            resetsAt: nil,
            errorMessage: errorMessage,
            language: .english
        )

        XCTAssertEqual(view.valueText, "Error")
        XCTAssertEqual(view.detailText, errorMessage)
        XCTAssertEqual(
            view.accessibilityText,
            "Weekly usage, Error, \(errorMessage)"
        )
    }

    func testUsesNativeStatusColorsAtRemainingThresholds() {
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 100), .systemGreen)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 50), .systemGreen)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 49), .systemOrange)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 20), .systemOrange)
        XCTAssertEqual(WeeklyUsageIndicatorView.progressColor(for: 19), .systemRed)
    }
}
