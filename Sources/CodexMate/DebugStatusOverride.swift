import Foundation

enum DebugStatusOverride {
    static let environmentKey = "CODEXMATE_DEBUG_STATUS"

    static func overallStatus(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppStateStore.OverallStatus? {
        guard let rawValue = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !rawValue.isEmpty else {
            return nil
        }

        switch rawValue {
        case "connecting":
            return .connecting
        case "idle":
            return .idle
        case "waiting", "waitingforuser", "waiting_for_user", "waiting-for-user":
            return .waitingForUser
        case "running":
            return .running
        case "failed", "error":
            return .failed
        default:
            return nil
        }
    }
}
