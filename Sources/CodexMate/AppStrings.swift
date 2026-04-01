import Foundation

struct AppStrings: Sendable {
    static let shared = AppStrings()

    private struct Catalog: Decodable {
        let en: [String: String]
        let ko: [String: String]
    }

    private let catalog: Catalog

    init(bundle: Bundle? = CodexMateResourceLocator.bundle) {
        guard let bundle,
              let url = bundle.url(forResource: "strings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            self.catalog = Catalog(en: [:], ko: [:])
            return
        }

        self.catalog = catalog
    }

    func text(_ key: String, language: AppLanguage) -> String {
        let localized = strings(for: language)[key]
        if let localized {
            return localized
        }

        if let fallback = catalog.en[key] {
            return fallback
        }

        return key
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
