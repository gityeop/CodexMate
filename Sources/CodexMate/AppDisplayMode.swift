import Foundation

enum AppDisplayMode: String, CaseIterable, Identifiable {
    case menuBar
    case notch

    var id: Self {
        self
    }

    static func fromStoredValue(_ rawValue: String?) -> AppDisplayMode {
        guard let rawValue else {
            return .notch
        }

        guard let mode = AppDisplayMode(rawValue: rawValue) else {
            preconditionFailure("Invalid stored display mode: \(rawValue)")
        }

        return mode
    }

    func resolved(hasHardwareNotch _: Bool) -> AppDisplayMode {
        self
    }
}
