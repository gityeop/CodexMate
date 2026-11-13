import Foundation

enum ClaudeUsageDisplayState: Equatable {
    /// Claude Desktop is not signed in on this Mac, so the row stays out of the way.
    case hidden
    case loading
    case loaded(ClaudeUsageReading)
    case failed(ClaudeUsageError?)

    static let staleReadingTolerance: TimeInterval = 30 * 60

    /// Keeps a recent reading through short network or rate-limit failures.
    static func state(
        afterFailure error: ClaudeUsageError?,
        previous: ClaudeUsageDisplayState,
        now: Date = Date()
    ) -> ClaudeUsageDisplayState {
        if error == .credentialsNotFound {
            return .hidden
        }

        if case let .loaded(reading) = previous,
           error?.needsClaudeDesktopSignInRefresh != true,
           now.timeIntervalSince(reading.readAt) < staleReadingTolerance {
            return previous
        }

        return .failed(error)
    }
}

enum ClaudeUsagePresentationBuilder {
    static func presentations(
        for state: ClaudeUsageDisplayState,
        language: AppLanguage,
        strings: AppStrings = .shared,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [WeeklyUsageIndicatorPresentation] {
        let titleText = strings.text("menu.claudeUsage.title", language: language)

        switch state {
        case .hidden:
            return []
        case .loading:
            return [WeeklyUsageIndicatorPresentation(
                titleText: titleText,
                valueText: strings.text("menu.weeklyUsage.loading", language: language),
                detailText: nil,
                remainingPercent: nil
            )]
        case let .failed(error):
            return [WeeklyUsageIndicatorPresentation(
                titleText: titleText,
                valueText: strings.text("menu.weeklyUsage.unavailable", language: language),
                detailText: error?.needsClaudeDesktopSignInRefresh == true
                    ? strings.text("menu.claudeUsage.signInHint", language: language)
                    : nil,
                remainingPercent: nil
            )]
        case let .loaded(reading):
            var segments: [WeeklyUsageBarSegment] = []
            var details: [String] = []

            if let fiveHour = reading.fiveHour {
                segments.append(WeeklyUsageBarSegment(
                    kind: .fiveHour,
                    remainingPercent: fiveHour.remainingPercent,
                    labelText: strings.format("menu.claudeUsage.fiveHour", language: language, Int64(fiveHour.remainingPercent))
                ))
                if let resetsAt = fiveHour.resetsAt {
                    details.append(
                        strings.format(
                            "menu.claudeUsage.fiveHourReset",
                            language: language,
                            formatter(template: "jm", language: language, timeZone: timeZone).string(from: resetsAt)
                        )
                    )
                }
            }

            if let sevenDay = reading.sevenDay {
                segments.append(WeeklyUsageBarSegment(
                    kind: .sevenDay,
                    remainingPercent: sevenDay.remainingPercent,
                    labelText: strings.format("menu.claudeUsage.sevenDay", language: language, Int64(sevenDay.remainingPercent))
                ))
                if let resetsAt = sevenDay.resetsAt {
                    details.append(
                        strings.format(
                            "menu.claudeUsage.sevenDayReset",
                            language: language,
                            formatter(template: "MMMd", language: language, timeZone: timeZone).string(from: resetsAt)
                        )
                    )
                }
            }

            var rows: [WeeklyUsageIndicatorPresentation] = []
            if !segments.isEmpty {
                rows.append(WeeklyUsageIndicatorPresentation(
                    titleText: titleText,
                    valueText: segments.map(\.labelText).joined(separator: " · "),
                    detailText: details.isEmpty ? nil : details.joined(separator: " · "),
                    remainingPercent: reading.lowestRemainingPercent,
                    barSegments: segments
                ))
            }

            let resetFormatter = formatter(template: "MMMdhm", language: language, timeZone: timeZone)
            rows += reading.modelWeeklyLimits.map { limit in
                WeeklyUsageIndicatorPresentation(
                    titleText: strings.format("menu.claudeUsage.modelWeekly", language: language, limit.modelName),
                    valueText: strings.format("menu.weeklyUsage.remaining", language: language, Int64(limit.window.remainingPercent)),
                    detailText: limit.window.resetsAt.map {
                        strings.format("menu.weeklyUsage.resets", language: language, resetFormatter.string(from: $0))
                    },
                    remainingPercent: limit.window.remainingPercent
                )
            }
            return rows
        }
    }

    private static func formatter(template: String, language: AppLanguage, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language.localeIdentifier)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}
