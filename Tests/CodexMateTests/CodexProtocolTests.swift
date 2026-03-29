import XCTest
@testable import CodexMate

final class CodexProtocolTests: XCTestCase {
    func testInitializeResponseDecodesCodexHomeWhenPresent() throws {
        let data = Data(
            """
            {
              "userAgent": "Codex/1.0",
              "codexHome": "/tmp/custom-codex-home"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(InitializeResponse.self, from: data)

        XCTAssertEqual(response.userAgent, "Codex/1.0")
        XCTAssertEqual(response.codexHome, "/tmp/custom-codex-home")
    }

    func testInitializeResponseAllowsMissingCodexHome() throws {
        let data = Data(
            """
            {
              "userAgent": "Codex/1.0"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(InitializeResponse.self, from: data)

        XCTAssertEqual(response.userAgent, "Codex/1.0")
        XCTAssertNil(response.codexHome)
    }

    func testCodexThreadDecodesPlainStringSource() throws {
        let thread = try decodeThread(
            sourceJSON: #""vscode""#
        )

        XCTAssertEqual(thread.source, "vscode")
        XCTAssertFalse(thread.isSubagent)
        XCTAssertNil(thread.subagentParentThreadID)
    }

    func testCodexThreadDecodesLegacySubagentStringSource() throws {
        let thread = try decodeThread(
            sourceJSON: #""{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent-thread\",\"depth\":1,\"agent_nickname\":\"Harvey\",\"agent_role\":\"explorer\"}}}""#
        )

        XCTAssertTrue(thread.isSubagent)
        XCTAssertEqual(thread.subagentParentThreadID, "parent-thread")
        XCTAssertEqual(
            thread.source,
            #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1,"agent_nickname":"Harvey","agent_role":"explorer"}}}"#
        )
    }

    func testCodexThreadDecodesObjectSubagentSource() throws {
        let thread = try decodeThread(
            sourceJSON: """
            {
              "subAgent": {
                "thread_spawn": {
                  "parent_thread_id": "parent-thread",
                  "depth": 1,
                  "agent_path": "/tmp/agent",
                  "agent_nickname": "Dalton",
                  "agent_role": "explorer"
                }
              }
            }
            """
        )

        XCTAssertTrue(thread.isSubagent)
        XCTAssertEqual(thread.subagentParentThreadID, "parent-thread")
        XCTAssertEqual(
            thread.source,
            #"{"subagent":{"thread_spawn":{"agent_nickname":"Dalton","agent_path":"/tmp/agent","agent_role":"explorer","depth":1,"parent_thread_id":"parent-thread"}}}"#
        )
    }

    func testThreadStartedNotificationDecodesObjectSubagentSource() throws {
        let data = Data(
            """
            {
              "thread": {
                "id": "thread-1",
                "preview": "Example",
                "createdAt": 100,
                "updatedAt": 123,
                "status": { "type": "notLoaded" },
                "cwd": "/tmp/example",
                "source": {
                  "subAgent": {
                    "thread_spawn": {
                      "parent_thread_id": "parent-thread",
                      "depth": 1,
                      "agent_nickname": "Dalton",
                      "agent_role": "explorer"
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let notification = try JSONDecoder().decode(ThreadStartedNotification.self, from: data)

        XCTAssertTrue(notification.thread.isSubagent)
        XCTAssertEqual(notification.thread.subagentParentThreadID, "parent-thread")
    }

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

    private func decodeThread(sourceJSON: String) throws -> CodexThread {
        let data = Data(
            """
            {
              "id": "thread-1",
              "preview": "Example",
              "createdAt": 100,
              "updatedAt": 123,
              "status": { "type": "notLoaded" },
              "cwd": "/tmp/example",
              "name": "Test thread",
              "source": \(sourceJSON)
            }
            """.utf8
        )

        return try JSONDecoder().decode(CodexThread.self, from: data)
    }
}
