import Foundation

enum AppDisplayMode: String, CaseIterable, Identifiable {
    case menuBar
    case notch

    var id: Self {
        self
    }

    static func fromStoredValue(_ rawValue: String?) -> AppDisplayMode {
        guard let rawValue, let mode = AppDisplayMode(rawValue: rawValue) else {
            return .notch
        }

        return mode
    }

    func resolved(hasHardwareNotch: Bool) -> AppDisplayMode {
        switch self {
        case .menuBar:
            return .menuBar
        case .notch:
            return hasHardwareNotch ? .notch : .menuBar
        }
    }
}
