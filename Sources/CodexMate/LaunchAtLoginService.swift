import Combine
import Foundation
import ServiceManagement

struct LaunchAtLoginSnapshot: Equatable {
    enum Status: Equatable {
        case unavailable
        case enabled
        case disabled
        case requiresApproval
        case error(message: String)
    }

    var status: Status

    var isAvailable: Bool {
        switch status {
        case .unavailable:
            return false
        case .enabled, .disabled, .requiresApproval, .error:
            return true
        }
    }

    var isEnabled: Bool {
        switch status {
        case .enabled:
            return true
        case .disabled, .unavailable, .requiresApproval, .error:
            return false
        }
    }
}

@MainActor
final class LaunchAtLoginService: ObservableObject {
    @Published private(set) var snapshot: LaunchAtLoginSnapshot

    private let isAppBundle: Bool
    private let statusProvider: () -> SMAppService.Status
    private let registerHandler: () throws -> Void
    private let unregisterHandler: () throws -> Void

    init(
        isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app",
        statusProvider: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        registerHandler: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregisterHandler: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.isAppBundle = isAppBundle
        self.statusProvider = statusProvider
        self.registerHandler = registerHandler
        self.unregisterHandler = unregisterHandler
        if isAppBundle {
            snapshot = Self.snapshot(from: statusProvider())
        } else {
            snapshot = LaunchAtLoginSnapshot(status: .unavailable)
        }
    }

    func refresh() {
        guard isAppBundle else {
            snapshot = LaunchAtLoginSnapshot(status: .unavailable)
            return
        }

        snapshot = Self.snapshot(from: statusProvider())
    }

    func setEnabled(_ isEnabled: Bool) {
        guard isAppBundle else {
            snapshot = LaunchAtLoginSnapshot(status: .unavailable)
            return
        }

        do {
            if isEnabled {
                try registerHandler()
            } else {
                try unregisterHandler()
            }
            refresh()
        } catch {
            snapshot = LaunchAtLoginSnapshot(status: .error(message: error.localizedDescription))
        }
    }

    private static func snapshot(from status: SMAppService.Status) -> LaunchAtLoginSnapshot {
        switch status {
        case .enabled:
            return LaunchAtLoginSnapshot(status: .enabled)
        case .requiresApproval:
            return LaunchAtLoginSnapshot(status: .requiresApproval)
        case .notRegistered, .notFound:
            return LaunchAtLoginSnapshot(status: .disabled)
        @unknown default:
            return LaunchAtLoginSnapshot(status: .disabled)
        }
    }
}
