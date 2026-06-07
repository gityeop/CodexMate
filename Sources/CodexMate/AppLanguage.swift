import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system
    case korean
    case english

    var id: String {
        rawValue
    }

    var resourceCode: String {
        switch self {
        case .system:
            return Self.systemResourceCode()
        case .korean:
            return "ko"
        case .english:
            return "en"
        }
    }

    var localeIdentifier: String {
        switch resourceCode {
        case "ko":
            return "ko_KR"
        default:
            return "en_US"
        }
    }

    static func fromStoredValue(_ rawValue: String?) -> AppLanguage {
        guard let rawValue else {
            return .system
        }

        guard let language = AppLanguage(rawValue: rawValue) else {
            preconditionFailure("Invalid stored app language: \(rawValue)")
        }

        return language
    }

    private static func systemResourceCode(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        guard let preferred = preferredLanguages.first?.lowercased() else {
            return "en"
        }

        return preferred.hasPrefix("ko") ? "ko" : "en"
    }
}
