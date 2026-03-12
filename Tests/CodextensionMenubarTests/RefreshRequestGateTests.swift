import XCTest
@testable import CodextensionMenubar

final class RefreshRequestGateTests: XCTestCase {
    func testBeginOrQueueStartsFirstRequest() {
        var gate = RefreshRequestGate()

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertTrue(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)
    }

    func testBeginOrQueueQueuesFollowUpWhileRunning() {
        var gate = RefreshRequestGate()

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertFalse(gate.beginOrQueue())
        XCTAssertTrue(gate.isRunning)
        XCTAssertTrue(gate.hasQueuedRequest)
    }

    func testFinishRequestsImmediateRerunWhenQueueExists() {
        var gate = RefreshRequestGate()

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertFalse(gate.beginOrQueue())
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)
    }

    func testFinishDoesNotRerunWithoutQueuedRequest() {
        var gate = RefreshRequestGate()

        XCTAssertTrue(gate.beginOrQueue())
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.isRunning)
        XCTAssertFalse(gate.hasQueuedRequest)
    }
}
