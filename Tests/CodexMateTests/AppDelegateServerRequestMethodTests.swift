import XCTest
@testable import CodexMate

final class AppDelegateServerRequestMethodTests: XCTestCase {
    func testClassifyServerRequestMethodRecognizesCanonicalUserInputMethods() {
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("item/tool/requestUserInput"),
            .toolUserInput
        )
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("tool/requestUserInput"),
            .toolUserInput
        )
    }

    func testClassifyServerRequestMethodRecognizesApprovalVariants() {
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("item/commandExecution/requestApproval"),
            .approval
        )
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("commandExecution/requestApproval"),
            .approval
        )
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("item/file_change/request_approval"),
            .approval
        )
    }

    func testClassifyServerRequestMethodRecognizesUserInputSnakeCaseVariants() {
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("item/tool/request_user_input"),
            .toolUserInput
        )
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("tool/request-user-input"),
            .toolUserInput
        )
    }

    func testClassifyServerRequestMethodIgnoresOtherRequests() {
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("thread/list"),
            .other
        )
        XCTAssertEqual(
            AppDelegate.classifyServerRequestMethod("serverRequest/resolved"),
            .other
        )
    }

    func testShouldHandleNotificationAsServerRequestRecognizesApprovalAndUserInput() {
        XCTAssertTrue(
            AppDelegate.shouldHandleNotificationAsServerRequest("item/commandExecution/requestApproval")
        )
        XCTAssertTrue(
            AppDelegate.shouldHandleNotificationAsServerRequest("tool/request-user-input")
        )
        XCTAssertFalse(
            AppDelegate.shouldHandleNotificationAsServerRequest("turn/completed")
        )
    }
}
