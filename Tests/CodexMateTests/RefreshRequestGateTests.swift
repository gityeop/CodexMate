import XCTest
@testable import CodexMate

final class RefreshRequestGateTests: XCTestCase {
    func testGateLifecycleTracksRunningQueuedAndRerunState() {
        var gate = RefreshRequestGate()

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)
        XCTAssertFalse(gate.beginOrQueue())
        XCTAssertTrue(gate.isRunning)
        XCTAssertTrue(gate.hasQueuedRequest)
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)
    }
}
