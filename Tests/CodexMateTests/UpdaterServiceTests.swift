import XCTest
@testable import CodexMate

@MainActor
final class UpdaterServiceTests: XCTestCase {
    func testNonAppBundleBuildIsUnavailable() {
        let service = UpdaterService(bundle: Bundle(for: Self.self))

        XCTAssertEqual(service.snapshot.status, .unavailable)
        XCTAssertFalse(service.snapshot.isAvailable)
    }

    func testSetAutomaticallyChecksForUpdatesUpdatesSnapshot() {
        var automaticChecks = false
        let service = UpdaterService(
            initialSnapshot: UpdaterSnapshot(
                status: .ready,
                automaticallyChecksForUpdates: automaticChecks,
                canCheckForUpdates: true
            ),
            refreshHandler: {
                UpdaterSnapshot(
                    status: .ready,
                    automaticallyChecksForUpdates: automaticChecks,
                    canCheckForUpdates: true
                )
            },
            setAutomaticallyChecksHandler: { isEnabled in
                automaticChecks = isEnabled
                return UpdaterSnapshot(
                    status: .ready,
                    automaticallyChecksForUpdates: automaticChecks,
                    canCheckForUpdates: true
                )
            },
            checkForUpdatesHandler: {}
        )

        service.setAutomaticallyChecksForUpdates(true)

        XCTAssertTrue(service.snapshot.automaticallyChecksForUpdates)
    }

    func testCheckForUpdatesInvokesHandlerAndRefreshesSnapshot() {
        var checkCount = 0
        let service = UpdaterService(
            initialSnapshot: UpdaterSnapshot(
                status: .ready,
                automaticallyChecksForUpdates: true,
                canCheckForUpdates: true
            ),
            refreshHandler: {
                UpdaterSnapshot(
                    status: .ready,
                    automaticallyChecksForUpdates: true,
                    canCheckForUpdates: true
                )
            },
            setAutomaticallyChecksHandler: { _ in
                UpdaterSnapshot(
                    status: .ready,
                    automaticallyChecksForUpdates: true,
                    canCheckForUpdates: true
                )
            },
            checkForUpdatesHandler: {
                checkCount += 1
            }
        )

        service.checkForUpdates()

        XCTAssertEqual(checkCount, 1)
        XCTAssertEqual(service.snapshot.status, .ready)
    }
}
