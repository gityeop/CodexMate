import XCTest
@testable import CodextensionMenubar

final class CodexDesktopStateReaderTests: XCTestCase {
    func testParseSessionPendingStateMarksUnresolvedRequestUserInputAsWaiting() {
        let contents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_waiting"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: true, needsApproval: false))
    }

    func testParseSessionPendingStateClearsWaitingWhenFunctionCallOutputArrives() {
        let contents = """
        {"timestamp":"2026-03-11T12:25:24.936Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}","call_id":"call_waiting"}}
        {"timestamp":"2026-03-11T12:50:10.223Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call_waiting","output":"{\\"answers\\":{}}"}}
        """

        let state = CodexDesktopStateReader.parseSessionPendingState(from: contents)

        XCTAssertEqual(state, .init(waitingForInput: false, needsApproval: false))
    }
}
