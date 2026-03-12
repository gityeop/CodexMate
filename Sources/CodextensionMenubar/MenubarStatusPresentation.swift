import Foundation

struct MenubarStatusPresentation {
    enum ThreadIndicator: Equatable {
        case unread
        case running
        case waitingForUser
        case failed
    }

    static func statusItemIcon(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) -> String {
        if hasUnreadThreads && overallStatus != .connecting && overallStatus != .running && overallStatus != .waitingForUser {
            return "🔵"
        }

        return overallStatus.icon
    }

    static func statusDisplayName(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) -> String {
        if hasUnreadThreads && overallStatus != .connecting && overallStatus != .running && overallStatus != .waitingForUser {
            return "Unread"
        }

        return overallStatus.displayName
    }

    static func threadTitle(for thread: AppStateStore.ThreadRow, relativeDate: String) -> String {
        "\(thread.displayTitle) | \(relativeDate)"
    }

    static func threadIndicator(for thread: AppStateStore.ThreadRow, hasUnreadContent: Bool) -> ThreadIndicator? {
        switch thread.presentationStatus {
        case .running:
            return .running
        case .waitingForUser:
            return .waitingForUser
        case .failed:
            return .failed
        case .idle, .notLoaded:
            return hasUnreadContent ? .unread : nil
        }
    }
}
