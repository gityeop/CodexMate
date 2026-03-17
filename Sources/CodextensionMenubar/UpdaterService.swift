import Combine
import Foundation
import Sparkle

struct UpdaterSnapshot: Equatable {
    enum Status: Equatable {
        case unavailable
        case ready
        case configurationIssue(message: String)
    }

    var status: Status
    var automaticallyChecksForUpdates: Bool
    var canCheckForUpdates: Bool

    var isAvailable: Bool {
        switch status {
        case .ready:
            return true
        case .unavailable, .configurationIssue:
            return false
        }
    }
}

@MainActor
final class UpdaterService: ObservableObject {
    @Published private(set) var snapshot: UpdaterSnapshot

    private let refreshHandler: () -> UpdaterSnapshot
    private let setAutomaticallyChecksHandler: (Bool) -> UpdaterSnapshot
    private let checkForUpdatesHandler: () -> Void

    init(
        bundle: Bundle = .main,
        controller: SPUStandardUpdaterController? = nil
    ) {
        if bundle.bundleURL.pathExtension != "app" {
            let unavailableSnapshot = UpdaterSnapshot(
                status: .unavailable,
                automaticallyChecksForUpdates: false,
                canCheckForUpdates: false
            )
            snapshot = unavailableSnapshot
            refreshHandler = { unavailableSnapshot }
            setAutomaticallyChecksHandler = { _ in unavailableSnapshot }
            checkForUpdatesHandler = {}
            return
        }

        guard let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.isEmpty,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.isEmpty else {
            let invalidSnapshot = UpdaterSnapshot(
                status: .configurationIssue(message: "Missing SUFeedURL or SUPublicEDKey."),
                automaticallyChecksForUpdates: false,
                canCheckForUpdates: false
            )
            snapshot = invalidSnapshot
            refreshHandler = { invalidSnapshot }
            setAutomaticallyChecksHandler = { _ in invalidSnapshot }
            checkForUpdatesHandler = {}
            return
        }

        let updaterController = controller ?? SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        refreshHandler = {
            UpdaterSnapshot(
                status: .ready,
                automaticallyChecksForUpdates: updaterController.updater.automaticallyChecksForUpdates,
                canCheckForUpdates: updaterController.updater.canCheckForUpdates
            )
        }
        setAutomaticallyChecksHandler = { isEnabled in
            updaterController.updater.automaticallyChecksForUpdates = isEnabled
            return UpdaterSnapshot(
                status: .ready,
                automaticallyChecksForUpdates: updaterController.updater.automaticallyChecksForUpdates,
                canCheckForUpdates: updaterController.updater.canCheckForUpdates
            )
        }
        checkForUpdatesHandler = {
            updaterController.checkForUpdates(nil)
        }
        snapshot = refreshHandler()
    }

    init(
        initialSnapshot: UpdaterSnapshot,
        refreshHandler: @escaping () -> UpdaterSnapshot,
        setAutomaticallyChecksHandler: @escaping (Bool) -> UpdaterSnapshot,
        checkForUpdatesHandler: @escaping () -> Void
    ) {
        snapshot = initialSnapshot
        self.refreshHandler = refreshHandler
        self.setAutomaticallyChecksHandler = setAutomaticallyChecksHandler
        self.checkForUpdatesHandler = checkForUpdatesHandler
    }

    func refresh() {
        snapshot = refreshHandler()
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        snapshot = setAutomaticallyChecksHandler(isEnabled)
    }

    func checkForUpdates() {
        checkForUpdatesHandler()
        refresh()
    }
}
