import XCTest
@testable import CodexMate

final class AppDelegateServerRequestMethodTests: XCTestCase {
    func testClassifyServerRequestMethodRecognizesKnownVariants() {
        let cases: [(method: String, expected: AppDelegate.ServerRequestKind)] = [
            ("item/tool/requestUserInput", .toolUserInput),
            ("tool/requestUserInput", .toolUserInput),
            ("item/tool/request_user_input", .toolUserInput),
            ("tool/request-user-input", .toolUserInput),
            ("item/commandExecution/requestApproval", .approval),
            ("commandExecution/requestApproval", .approval),
            ("item/file_change/request_approval", .approval),
            ("thread/list", .other),
            ("serverRequest/resolved", .other),
        ]

        for testCase in cases {
            XCTAssertEqual(
                AppDelegate.classifyServerRequestMethod(testCase.method),
                testCase.expected,
                "method=\(testCase.method)"
            )
        }
    }

    func testShouldHandleNotificationAsServerRequestRecognizesKnownSignalsOnly() {
        let truthyMethods = [
            "item/commandExecution/requestApproval",
            "tool/request-user-input",
        ]
        let falsyMethods = [
            "turn/completed",
            "thread/list",
        ]

        for method in truthyMethods {
            XCTAssertTrue(
                AppDelegate.shouldHandleNotificationAsServerRequest(method),
                "method=\(method)"
            )
        }

        for method in falsyMethods {
            XCTAssertFalse(
                AppDelegate.shouldHandleNotificationAsServerRequest(method),
                "method=\(method)"
            )
        }
    }
}
