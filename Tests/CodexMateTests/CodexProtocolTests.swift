import XCTest
@testable import CodexMate

final class CodexProtocolTests: XCTestCase {
    func testDisplayTitleUsesSecondLineWhenFirstLineIsTooShort() {
        let thread = CodexThread(
            id: "thread-1",
            preview: "ignored",
            createdAt: 1,
            updatedAt: 1,
            status: .idle,
            cwd: "/tmp/example",
            name: "알림\n승인 또는 입력 필요\n작업 완료"
        )

        XCTAssertEqual(thread.displayTitle, "알림 승인 또는 입력 필요")
    }

    func testDisplayTitleFallsBackToNormalizedPreviewWhenNameIsMissing() {
        let thread = CodexThread(
            id: "thread-1",
            preview: "첫 줄\n두 번째 줄",
            createdAt: 1,
            updatedAt: 1,
            status: .idle,
            cwd: "/tmp/example",
            name: nil
        )

        XCTAssertEqual(thread.displayTitle, "첫 줄 두 번째 줄")
    }
}
