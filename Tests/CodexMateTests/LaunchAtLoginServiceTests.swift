import ServiceManagement
import XCTest
@testable import CodexMate

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testSetEnabledRegistersAndUnregistersMainApp() {
        var isRegistered = false
        let service = LaunchAtLoginService(
            isAppBundle: true,
            statusProvider: { isRegistered ? .enabled : .notRegistered },
            registerHandler: {
                isRegistered = true
            },
            unregisterHandler: {
                isRegistered = false
            }
        )

        XCTAssertEqual(service.snapshot.status, .disabled)

        service.setEnabled(true)
        XCTAssertEqual(service.snapshot.status, .enabled)

        service.setEnabled(false)
        XCTAssertEqual(service.snapshot.status, .disabled)
    }

    func testSnapshotReflectsUnavailableAndApprovalStates() {
        let unavailableService = LaunchAtLoginService(isAppBundle: false)
        let requiresApprovalService = LaunchAtLoginService(
            isAppBundle: true,
            statusProvider: { .requiresApproval },
            registerHandler: {},
            unregisterHandler: {}
        )

        XCTAssertEqual(unavailableService.snapshot.status, .unavailable)
        XCTAssertFalse(unavailableService.snapshot.isAvailable)
        XCTAssertEqual(requiresApprovalService.snapshot.status, .requiresApproval)
    }
}
