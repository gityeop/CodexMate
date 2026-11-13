import Foundation

struct ClaudeUsageWindow: Equatable, Sendable {
    let remainingPercent: Int
    let resetsAt: Date?
}

struct ClaudeUsageReading: Equatable, Sendable {
    struct ModelWeeklyLimit: Equatable, Sendable {
        let modelName: String
        let window: ClaudeUsageWindow
    }

    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let modelWeeklyLimits: [ModelWeeklyLimit]
    let readAt: Date

    var lowestRemainingPercent: Int? {
        [fiveHour?.remainingPercent, sevenDay?.remainingPercent]
            .compactMap { $0 }
            .min()
    }
}

enum ClaudeUsageError: LocalizedError, Equatable {
    case credentialsNotFound
    case desktopCredentialsInvalid
    case keychainReadFailed(Int32)
    case decryptionFailed(Int32)
    case tokenExpired
    case unauthorized
    case httpStatus(Int)
    case usageWindowsUnavailable

    /// Expired or rejected sign-in tokens are refreshed by Claude Desktop itself, not by CodexMate.
    var needsClaudeDesktopSignInRefresh: Bool {
        switch self {
        case .tokenExpired, .unauthorized:
            return true
        case .credentialsNotFound, .desktopCredentialsInvalid, .keychainReadFailed, .decryptionFailed, .httpStatus, .usageWindowsUnavailable:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return "Claude Desktop sign-in credentials were not found."
        case .desktopCredentialsInvalid:
            return "The Claude Desktop credential cache is invalid."
        case let .keychainReadFailed(status):
            return "Claude Desktop Safe Storage keychain lookup failed (status \(status))."
        case let .decryptionFailed(status):
            return "Claude Desktop credential decryption failed (status \(status))."
        case .tokenExpired:
            return "The Claude Desktop access token has expired."
        case .unauthorized:
            return "The Claude usage endpoint rejected the Claude Desktop access token."
        case let .httpStatus(statusCode):
            return "The Claude usage endpoint returned HTTP \(statusCode)."
        case .usageWindowsUnavailable:
            return "The Claude usage response did not include any usage windows."
        }
    }
}

struct ClaudeOAuthCredentials: Equatable, Sendable {
    let accessToken: String
    let expiresAt: Date?

    func isExpired(at date: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else {
            return false
        }

        return expiresAt <= date.addingTimeInterval(leeway)
    }
}

enum ClaudeUsageParser {
    private struct Response: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        let limits: [Limit]?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable {
                let displayName: String

                enum CodingKeys: String, CodingKey {
                    case displayName = "display_name"
                }
            }

            let model: Model?
        }

        let kind: String
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        enum CodingKeys: String, CodingKey {
            case kind, percent, scope
            case resetsAt = "resets_at"
        }
    }

    static func reading(from data: Data, readAt: Date = Date()) throws -> ClaudeUsageReading {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let modelWeeklyLimits = (response.limits ?? []).compactMap { limit -> ClaudeUsageReading.ModelWeeklyLimit? in
            guard limit.kind == "weekly_scoped",
                  let model = limit.scope?.model,
                  let window = window(utilization: limit.percent, resetsAt: limit.resetsAt) else {
                return nil
            }
            return ClaudeUsageReading.ModelWeeklyLimit(modelName: model.displayName, window: window)
        }
        let reading = ClaudeUsageReading(
            fiveHour: window(utilization: response.fiveHour?.utilization, resetsAt: response.fiveHour?.resetsAt),
            sevenDay: window(utilization: response.sevenDay?.utilization, resetsAt: response.sevenDay?.resetsAt),
            modelWeeklyLimits: modelWeeklyLimits,
            readAt: readAt
        )

        guard reading.fiveHour != nil || reading.sevenDay != nil || !reading.modelWeeklyLimits.isEmpty else {
            throw ClaudeUsageError.usageWindowsUnavailable
        }

        return reading
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let date = plainFormatter.date(from: value) {
            return date
        }

        // Some responses carry microseconds, which older ISO8601 parsers reject.
        guard let fractionRange = value.range(of: #"\.\d+"#, options: .regularExpression) else {
            return nil
        }
        var withoutFraction = value
        withoutFraction.removeSubrange(fractionRange)
        return plainFormatter.date(from: withoutFraction)
    }

    private static func window(utilization: Double?, resetsAt: String?) -> ClaudeUsageWindow? {
        guard let utilization, utilization.isFinite else {
            return nil
        }

        let usedPercent = min(max(Int(utilization.rounded()), 0), 100)
        return ClaudeUsageWindow(
            remainingPercent: 100 - usedPercent,
            resetsAt: parseTimestamp(resetsAt)
        )
    }
}
