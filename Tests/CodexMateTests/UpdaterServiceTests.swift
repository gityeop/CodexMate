import XCTest
@testable import CodexMate

@MainActor
final class UpdaterServiceTests: XCTestCase {
    func testAppBundleWithoutSparkleMetadataIsUnavailable() throws {
        let bundle = try makeAppBundle(infoDictionary: [:])
        let service = UpdaterService(bundle: bundle)

        XCTAssertEqual(service.snapshot.status, .unavailable)
        XCTAssertFalse(service.snapshot.isAvailable)
    }

    func testAppBundleWithInvalidFeedURLReportsConfigurationIssue() throws {
        let bundle = try makeAppBundle(
            infoDictionary: [
                "SUFeedURL": "not a url",
                "SUPublicEDKey": "public-key",
            ]
        )
        let service = UpdaterService(bundle: bundle)

        XCTAssertEqual(service.snapshot.status, .configurationIssue(message: "Invalid SUFeedURL."))
        XCTAssertFalse(service.snapshot.isAvailable)
    }

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

    private func makeAppBundle(infoDictionary: [String: String]) throws -> Bundle {
        let fileManager = FileManager.default
        let bundleURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")

        try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist = infoDictionary.merging([
            "CFBundleIdentifier": "com.example.codexmate.tests",
            "CFBundleName": "CodexMateTests",
            "CFBundleExecutable": "CodexMateTests",
            "CFBundlePackageType": "APPL",
        ]) { current, _ in current }
        let plistData = try XCTUnwrap(
            PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
        )
        try plistData.write(to: plistURL)
        addTeardownBlock {
            try? fileManager.removeItem(at: bundleURL)
        }

        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}
