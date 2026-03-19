import ServiceManagement
import XCTest
@testable import CodexMate

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
    func testServiceIsUnavailableOutsideAppBundle() {
        let service = LaunchAtLoginService(isAppBundle: false)

        XCTAssertEqual(service.snapshot.status, .unavailable)
        XCTAssertFalse(service.snapshot.isAvailable)
    }

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

    func testRequiresApprovalStatusIsSurfaced() {
        let service = LaunchAtLoginService(
            isAppBundle: true,
            statusProvider: { .requiresApproval },
            registerHandler: {},
            unregisterHandler: {}
        )

        XCTAssertEqual(service.snapshot.status, .requiresApproval)
    }
}
