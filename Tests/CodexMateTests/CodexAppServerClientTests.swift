import XCTest
@testable import CodexMate

final class CodexAppServerClientTests: XCTestCase {
    func testTerminationAfterLaunchReportsFailureWithoutCrashing() async throws {
        let client = CodexAppServerClient()
        let terminationExpectation = expectation(description: "termination callback")
        let binaryURL = try makeFakeCodexBinary()

        await client.setCallbacks(
            onMessage: { _ in },
            onTermination: { reason in
                XCTAssertEqual(reason, "Codex app-server exited with status 0")
                terminationExpectation.fulfill()
            }
        )

        let response = try await client.start(codexBinaryURL: binaryURL)

        XCTAssertEqual(response.userAgent, "CodexMateTests")
        XCTAssertEqual(response.codexHome, "/tmp/codexmate-tests")

        await fulfillment(of: [terminationExpectation], timeout: 2.0)
    }

    func testRestartAfterStopIgnoresTerminationFromPreviousConnection() async throws {
        let client = CodexAppServerClient()
        let binaryURL = try makeFakeCodexBinary(
            delayedShutdownSeconds: 0.4,
            keepRunningUntilStopped: true
        )
        let unexpectedTerminationExpectation = expectation(description: "unexpected termination")
        unexpectedTerminationExpectation.isInverted = true

        await client.setCallbacks(
            onMessage: { _ in },
            onTermination: { _ in
                unexpectedTerminationExpectation.fulfill()
            }
        )

        _ = try await client.start(codexBinaryURL: binaryURL)
        let isConnectedAfterFirstStart = await client.isConnected()
        XCTAssertTrue(isConnectedAfterFirstStart)

        await client.stop()

        _ = try await client.start(codexBinaryURL: binaryURL)
        let isConnectedAfterRestart = await client.isConnected()
        XCTAssertTrue(isConnectedAfterRestart)

        await fulfillment(of: [unexpectedTerminationExpectation], timeout: 0.8)
        let isConnectedAfterOldTermination = await client.isConnected()
        XCTAssertTrue(isConnectedAfterOldTermination)

        await client.stop()
    }

    func testDescribeDecodingErrorIncludesMissingKeyAndPath() {
        let error = DecodingError.keyNotFound(
            DynamicCodingKey(stringValue: "preview")!,
            .init(
                codingPath: [
                    DynamicCodingKey(stringValue: "data")!,
                    DynamicCodingKey(intValue: 12)!
                ],
                debugDescription: "missing"
            )
        )

        XCTAssertEqual(
            describeDecodingError(error),
            "missing key 'preview' at data.[12]"
        )
    }

    func testDescribeDecodingErrorUsesRootForEmptyPath() {
        let error = DecodingError.valueNotFound(
            String.self,
            .init(codingPath: [], debugDescription: "missing")
        )

        XCTAssertEqual(
            describeDecodingError(error),
            "missing value at <root>"
        )
    }

    func testThreadListResponseFallsBackCreatedAtToUpdatedAtWhenMissing() throws {
        let data = Data(
            """
            {
              "data": [
                {
                  "id": "thread-1",
                  "preview": "Example",
                  "updatedAt": 123,
                  "status": { "type": "notLoaded" },
                  "cwd": "/tmp/example",
                  "name": "Test thread"
                }
              ],
              "nextCursor": null
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(ThreadListResponse.self, from: data)

        XCTAssertEqual(response.data.count, 1)
        XCTAssertEqual(response.data[0].createdAt, 123)
        XCTAssertEqual(response.data[0].updatedAt, 123)
    }

    func testThreadListParamsEncodeCursorAndUpdatedAtSortKey() throws {
        let data = try JSONEncoder().encode(
            ThreadListParams(cursor: "cursor-1", limit: 64, sortKey: .updatedAt, archived: false)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["cursor"] as? String, "cursor-1")
        XCTAssertEqual(object["limit"] as? Int, 64)
        XCTAssertEqual(object["sortKey"] as? String, "updated_at")
        XCTAssertEqual(object["archived"] as? Bool, false)
    }

    func testThreadUnsubscribeParamsEncodeThreadID() throws {
        let data = try JSONEncoder().encode(ThreadUnsubscribeParams(threadId: "thread-1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["threadId"] as? String, "thread-1")
    }
    private func makeFakeCodexBinary(
        delayedShutdownSeconds: TimeInterval = 0,
        keepRunningUntilStopped: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let scriptURL = directoryURL.appendingPathComponent("fake-codex.zsh")
        let script = """
        #!/bin/zsh
        delayed_shutdown=\(delayedShutdownSeconds)
        keep_running_until_stopped=\(keepRunningUntilStopped ? 1 : 0)
        if [[ "$delayed_shutdown" != "0.0" ]]; then
          trap "sleep $delayed_shutdown; exit 0" TERM INT
        fi
        read -r request || exit 1
        request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
        [[ -n "$request_id" ]] || request_id=1
        printf '{"jsonrpc":"2.0","id":%s,"result":{"userAgent":"CodexMateTests","codexHome":"/tmp/codexmate-tests"}}\n' "$request_id"
        if [[ "$keep_running_until_stopped" == "1" ]]; then
          while read -r _; do
            :
          done
        else
          read -r _ || exit 0
        fi
        if [[ "$delayed_shutdown" != "0.0" ]]; then
          sleep "$delayed_shutdown"
        fi
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: scriptURL.path),
            "Expected fake codex binary to be executable",
            file: file,
            line: line
        )

        return scriptURL
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
