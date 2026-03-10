import Foundation

struct MenubarStatusPresentation {
    enum ThreadIndicator: Equatable {
        case unread
        case running
        case waitingForInput
        case needsApproval
        case failed
    }

    static func statusItemIcon(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) -> String {
        if overallStatus == .idle && hasUnreadThreads {
            return "🔵"
        }

        return overallStatus.icon
    }

    static func statusDisplayName(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) -> String {
        if overallStatus == .idle && hasUnreadThreads {
            return "Unread"
        }

        return overallStatus.displayName
    }

    static func threadTitle(for thread: AppStateStore.ThreadRow, relativeDate: String) -> String {
        "\(thread.displayTitle) | \(relativeDate)"
    }

    static func threadIndicator(for thread: AppStateStore.ThreadRow, hasUnreadContent: Bool) -> ThreadIndicator? {
        switch thread.displayStatus {
        case .running:
            return .running
        case .waitingForInput:
            return .waitingForInput
        case .needsApproval:
            return .needsApproval
        case .failed:
            return .failed
        case .idle, .notLoaded:
            return hasUnreadContent ? .unread : nil
        }
    }
}
