import Foundation

enum ThreadListViewMode: String, CaseIterable, Identifiable {
    case projects
    case recent
    case status

    var id: Self {
        self
    }

    static func fromStoredValue(_ rawValue: String?) -> ThreadListViewMode {
        guard let rawValue else {
            return .projects
        }

        guard let mode = ThreadListViewMode(rawValue: rawValue) else {
            preconditionFailure("Invalid stored thread list view mode: \(rawValue)")
        }

        return mode
    }
}
