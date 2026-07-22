import Foundation

struct AccountRateLimitsResponse: Decodable, Sendable {
    let rateLimits: AccountRateLimitSnapshot
}

struct AccountRateLimitSnapshot: Decodable, Sendable {
    let primary: AccountRateLimitWindow?
    let secondary: AccountRateLimitWindow?
}

struct AccountRateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

struct WeeklyUsageReading: Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?
    let readAt: Date
}

enum WeeklyUsageError: LocalizedError, Equatable {
    case weeklyWindowUnavailable

    var errorDescription: String? {
        switch self {
        case .weeklyWindowUnavailable:
            return "The default Codex rate-limit response did not include a 7-day window."
        }
    }
}

enum WeeklyUsageParser {
    static let weeklyWindowDurationMinutes: Int64 = 7 * 24 * 60

    static func reading(
        from response: AccountRateLimitsResponse,
        readAt: Date = Date()
    ) throws -> WeeklyUsageReading {
        let windows = [
            response.rateLimits.primary,
            response.rateLimits.secondary,
        ].compactMap { $0 }

        guard let weeklyWindow = windows.first(where: {
            $0.windowDurationMins == weeklyWindowDurationMinutes
        }) else {
            throw WeeklyUsageError.weeklyWindowUnavailable
        }

        let usedPercent = min(max(weeklyWindow.usedPercent, 0), 100)
        return WeeklyUsageReading(
            remainingPercent: 100 - usedPercent,
            resetsAt: weeklyWindow.resetsAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            readAt: readAt
        )
    }
}
