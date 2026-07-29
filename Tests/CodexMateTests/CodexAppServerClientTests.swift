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

    func testStartTimesOutAndCleansUpWhenInitializeDoesNotRespond() async throws {
        let client = CodexAppServerClient(requestTimeout: 0.1)
        let binaryURL = try makeFakeCodexBinary(respondsToInitialize: false)

        do {
            _ = try await client.start(codexBinaryURL: binaryURL)
            XCTFail("Expected start to time out")
        } catch let error as CodexAppServerClientError {
            guard case let .requestTimedOut(method, seconds) = error else {
                return XCTFail("Expected request timeout, got \(error)")
            }
            XCTAssertEqual(method, "initialize")
            XCTAssertEqual(seconds, 0.1, accuracy: 0.01)
        }

        let isConnected = await client.isConnected()
        XCTAssertFalse(isConnected)
    }

    func testCallAcceptsAResponseThatArrivesBeforeTheTimeout() async throws {
        let client = CodexAppServerClient(requestTimeout: 0.5)
        let binaryURL = try makeFakeCodexBinary(firstRateLimitsResponseDelaySeconds: 0.1)

        _ = try await client.start(codexBinaryURL: binaryURL)
        let response: AccountRateLimitsResponse = try await client.call(
            method: "account/rateLimits/read"
        )

        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 25)
        await client.stop()
    }

    func testTimedOutCallDoesNotPreventTheNextCallFromSucceeding() async throws {
        let client = CodexAppServerClient(requestTimeout: 0.5)
        let binaryURL = try makeFakeCodexBinary(firstRateLimitsResponseDelaySeconds: 0.8)

        _ = try await client.start(codexBinaryURL: binaryURL)

        do {
            let _: AccountRateLimitsResponse = try await client.call(
                method: "account/rateLimits/read"
            )
            XCTFail("Expected the first call to time out")
        } catch let error as CodexAppServerClientError {
            guard case let .requestTimedOut(method, seconds) = error else {
                return XCTFail("Expected request timeout, got \(error)")
            }
            XCTAssertEqual(method, "account/rateLimits/read")
            XCTAssertEqual(seconds, 0.5, accuracy: 0.01)
        }

        try await Task.sleep(nanoseconds: 850_000_000)

        let response: AccountRateLimitsResponse = try await client.call(
            method: "account/rateLimits/read"
        )
        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 25)

        await client.stop()
    }

    func testStandardErrorLineIsReportedAsADiagnostic() async throws {
        let client = CodexAppServerClient(requestTimeout: 0.5)
        let binaryURL = try makeFakeCodexBinary(
            firstRateLimitsResponseDelaySeconds: 0,
            emitsRateLimitsDiagnostic: true
        )
        let diagnosticExpectation = expectation(description: "app-server diagnostic")

        await client.setCallbacks(
            onMessage: { message in
                guard case let .diagnostic(text) = message else { return }
                XCTAssertEqual(text, "rate-limit diagnostic")
                diagnosticExpectation.fulfill()
            },
            onTermination: nil
        )

        _ = try await client.start(codexBinaryURL: binaryURL)
        let _: AccountRateLimitsResponse = try await client.call(
            method: "account/rateLimits/read"
        )

        await fulfillment(of: [diagnosticExpectation], timeout: 1.0)
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

    func testThreadListResponseRequiresCreatedAt() throws {
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

        XCTAssertThrowsError(try JSONDecoder().decode(ThreadListResponse.self, from: data)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                XCTFail("Expected missing createdAt error, got \(error)")
                return
            }

            XCTAssertEqual(key.stringValue, "createdAt")
        }
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

    private func makeFakeCodexBinary(
        delayedShutdownSeconds: TimeInterval = 0,
        keepRunningUntilStopped: Bool = false,
        respondsToInitialize: Bool = true,
        firstRateLimitsResponseDelaySeconds: TimeInterval? = nil,
        emitsRateLimitsDiagnostic: Bool = false,
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
        responds_to_initialize=\(respondsToInitialize ? 1 : 0)
        responds_to_rate_limits=\(firstRateLimitsResponseDelaySeconds == nil ? 0 : 1)
        first_rate_limits_response_delay=\(firstRateLimitsResponseDelaySeconds ?? 0)
        emits_rate_limits_diagnostic=\(emitsRateLimitsDiagnostic ? 1 : 0)
        if [[ "$delayed_shutdown" != "0.0" ]]; then
          trap "sleep $delayed_shutdown; exit 0" TERM INT
        fi
        read -r request || exit 1
        if [[ "$responds_to_initialize" != "1" ]]; then
          while read -r _; do
            :
          done
          exit 0
        fi
        request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
        [[ -n "$request_id" ]] || request_id=1
        printf '{"jsonrpc":"2.0","id":%s,"result":{"userAgent":"CodexMateTests","codexHome":"/tmp/codexmate-tests"}}\n' "$request_id"
        read -r _ || exit 0
        if [[ "$responds_to_rate_limits" == "1" ]]; then
          rate_limits_request_count=0
          while read -r request; do
            rate_limits_request_count=$((rate_limits_request_count + 1))
            if [[ "$emits_rate_limits_diagnostic" == "1" && "$rate_limits_request_count" == "1" ]]; then
              printf '%s\n' 'rate-limit diagnostic' >&2
            fi
            if [[ "$rate_limits_request_count" == "1" && "$first_rate_limits_response_delay" != "0.0" ]]; then
              sleep "$first_rate_limits_response_delay"
            fi
            request_id=$(printf '%s\n' "$request" | sed -n 's/.*"id":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p')
            [[ -n "$request_id" ]] || exit 1
            printf '{"jsonrpc":"2.0","id":%s,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":2000000000},"secondary":null}}}\n' "$request_id"
          done
        elif [[ "$keep_running_until_stopped" == "1" ]]; then
          while read -r _; do
            :
          done
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
