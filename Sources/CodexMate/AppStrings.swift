import Foundation

struct AppStrings: Sendable {
    static let shared = AppStrings()

    private struct Catalog: Decodable {
        let en: [String: String]
        let ko: [String: String]
    }

    private let catalog: Catalog

    init(bundle: Bundle? = CodexMateResourceLocator.bundle) {
        guard let bundle else {
            preconditionFailure("Missing CodexMate resource bundle.")
        }
        guard let url = bundle.url(forResource: "strings", withExtension: "json") else {
            preconditionFailure("Missing strings.json in CodexMate resource bundle.")
        }

        do {
            let data = try Data(contentsOf: url)
            self.catalog = try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            preconditionFailure("Failed to load strings.json: \(error.localizedDescription)")
        }
    }

    func text(_ key: String, language: AppLanguage) -> String {
        guard let localized = strings(for: language)[key] else {
            preconditionFailure("Missing localized string for key '\(key)' and language '\(language.resourceCode)'.")
        }

        return localized
    }

    func format(_ key: String, language: AppLanguage, _ arguments: CVarArg...) -> String {
        let format = text(key, language: language)
        return String(format: format, locale: Locale(identifier: language.localeIdentifier), arguments: arguments)
    }

    private func strings(for language: AppLanguage) -> [String: String] {
        switch language.resourceCode {
        case "ko":
            return catalog.ko
        default:
            return catalog.en
        }
    }
}
