import Foundation
import XCTest
@testable import CodexMate

final class ClaudeUsageParserTests: XCTestCase {
    func testParsesBothWindowsWithMicrosecondTimestamps() throws {
        let data = Data(
            """
            {
              "five_hour": {"utilization": 37.0, "resets_at": "2026-02-08T04:59:59.000000+00:00"},
              "seven_day": {"utilization": 26.4, "resets_at": "2026-02-12T14:59:59.771647+00:00"},
              "seven_day_opus": {"utilization": 1.0, "resets_at": null},
              "extra_usage": null
            }
            """.utf8
        )
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)

        let reading = try ClaudeUsageParser.reading(from: data, readAt: readAt)

        XCTAssertEqual(reading.fiveHour?.remainingPercent, 63)
        XCTAssertEqual(reading.sevenDay?.remainingPercent, 74)
        XCTAssertEqual(reading.lowestRemainingPercent, 63)
        XCTAssertEqual(reading.readAt, readAt)
        XCTAssertEqual(
            reading.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0,
            Date(timeIntervalSince1970: 1_770_526_799).timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertNotNil(reading.sevenDay?.resetsAt)
    }

    func testClampsUtilizationAndKeepsSingleWindow() throws {
        let data = Data(#"{"five_hour": {"utilization": 140.0, "resets_at": "2026-02-08T04:59:59Z"}, "seven_day": null}"#.utf8)

        let reading = try ClaudeUsageParser.reading(from: data)

        XCTAssertEqual(reading.fiveHour?.remainingPercent, 0)
        XCTAssertNil(reading.sevenDay)
        XCTAssertEqual(reading.lowestRemainingPercent, 0)
    }

    func testThrowsWhenNoUsageWindowIsPresent() {
        let data = Data(#"{"five_hour": null, "seven_day": {"utilization": null}}"#.utf8)

        XCTAssertThrowsError(try ClaudeUsageParser.reading(from: data)) { error in
            XCTAssertEqual(error as? ClaudeUsageError, .usageWindowsUnavailable)
        }
    }

    func testParsesDesktopCredentialsForSignedInAccountAndGeneralScope() throws {
        let data = Data(
            #"{"acct:other|9d1c250a-e61b-44d9-88ed-5944d1962f5e:org:https://api.anthropic.com:user:inference user:file_upload user:profile":{"token":"other-account","expiresAt":1800000000000},"acct:current|9d1c250a-e61b-44d9-88ed-5944d1962f5e:org:https://api.anthropic.com:user:inference user:file_upload user:profile user:sessions:claude_code":{"token":"code-token","expiresAt":1800000000000},"acct:current|9d1c250a-e61b-44d9-88ed-5944d1962f5e:org:https://api.anthropic.com:user:inference user:file_upload user:profile":{"token":"desktop-token","expiresAt":1800000000000}}"#.utf8
        )

        let credentials = try ClaudeDesktopCredentialsParser.credentials(from: data, accountUUID: "current")

        XCTAssertEqual(credentials.accessToken, "desktop-token")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(credentials.isExpired(at: Date(timeIntervalSince1970: 1_799_000_000)))
        XCTAssertTrue(credentials.isExpired(at: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertThrowsError(try ClaudeDesktopCredentialsParser.credentials(from: data, accountUUID: "signed-out")) {
            XCTAssertEqual($0 as? ClaudeUsageError, .credentialsNotFound)
        }
    }

    func testDecryptsElectronSafeStorageFixture() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: "djEwy8O2MWE5YNK/z6YhTAbEMIu1aGGAHJOA3RReZZKitY8="))

        let plaintext = try ClaudeDesktopCredentialsStore.decrypt(encrypted, password: Data("test-password".utf8))

        XCTAssertEqual(String(data: plaintext, encoding: .utf8), #"{"token":"test-desktop-token"}"#)
        XCTAssertThrowsError(try ClaudeDesktopCredentialsParser.credentials(
            from: ClaudeDesktopCredentialsStore.decrypt(encrypted, password: Data("wrong".utf8)),
            accountUUID: "current"
        ))
        XCTAssertThrowsError(try ClaudeDesktopCredentialsStore.decrypt(Data(encrypted.dropLast()), password: Data("test-password".utf8)))
        XCTAssertThrowsError(try ClaudeDesktopCredentialsStore.decrypt(Data("v20invalid".utf8), password: Data())) {
            XCTAssertEqual($0 as? ClaudeUsageError, .desktopCredentialsInvalid)
        }
    }

}

final class ClaudeUsageServiceTests: XCTestCase {
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var authorizations: [String] = []
        private var betaHeaders: [String] = []

        func record(_ request: URLRequest) {
            lock.lock()
            authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            betaHeaders.append(request.value(forHTTPHeaderField: "anthropic-beta") ?? "")
            lock.unlock()
        }

        var recordedAuthorizations: [String] {
            lock.lock()
            defer { lock.unlock() }
            return authorizations
        }

        var recordedBetaHeaders: [String] {
            lock.lock()
            defer { lock.unlock() }
            return betaHeaders
        }
    }

    private final class CredentialsSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String]

        init(tokens: [String]) {
            self.tokens = tokens
        }

        func next() throws -> ClaudeOAuthCredentials {
            lock.lock()
            defer { lock.unlock() }
            guard let token = tokens.first else { throw ClaudeUsageError.credentialsNotFound }
            if tokens.count > 1 {
                tokens.removeFirst()
            }
            return ClaudeOAuthCredentials(accessToken: token, expiresAt: Date(timeIntervalSince1970: 4_102_444_800))
        }
    }

    private static let usageBody = Data(
        #"{"five_hour":{"utilization":10.0,"resets_at":"2026-02-08T04:59:59Z"},"seven_day":{"utilization":50.0,"resets_at":"2026-02-12T14:59:59Z"}}"#.utf8
    )

    func testSendsDesktopTokenAndBetaHeader() async throws {
        let log = RequestLog()
        let service = ClaudeUsageService(
            loadCredentials: { try CredentialsSequence(tokens: ["token-a"]).next() },
            fetch: { request in
                log.record(request)
                return ClaudeUsageHTTPResponse(statusCode: 200, body: Self.usageBody)
            }
        )

        let reading = try await service.read()

        XCTAssertEqual(reading.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(reading.sevenDay?.remainingPercent, 50)
        XCTAssertEqual(log.recordedAuthorizations, ["Bearer token-a"])
        XCTAssertEqual(log.recordedBetaHeaders, [ClaudeUsageService.betaHeaderValue])
    }

    func testRetriesOnceWithRotatedTokenAfterUnauthorized() async throws {
        let log = RequestLog()
        let credentials = CredentialsSequence(tokens: ["old-token", "new-token"])
        let service = ClaudeUsageService(
            loadCredentials: { try credentials.next() },
            fetch: { request in
                log.record(request)
                let isNewToken = request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token"
                return ClaudeUsageHTTPResponse(statusCode: isNewToken ? 200 : 401, body: Self.usageBody)
            }
        )

        let reading = try await service.read()

        XCTAssertEqual(reading.fiveHour?.remainingPercent, 90)
        XCTAssertEqual(log.recordedAuthorizations, ["Bearer old-token", "Bearer new-token"])
    }

    func testReadsDesktopTokenAgainOnEachRefresh() async throws {
        let log = RequestLog()
        let credentials = CredentialsSequence(tokens: ["first-token", "refreshed-token"])
        let service = ClaudeUsageService(
            loadCredentials: { try credentials.next() },
            fetch: { request in
                log.record(request)
                return ClaudeUsageHTTPResponse(statusCode: 200, body: Self.usageBody)
            }
        )

        _ = try await service.read()
        _ = try await service.read()

        XCTAssertEqual(log.recordedAuthorizations, ["Bearer first-token", "Bearer refreshed-token"])
    }

    func testCredentialReadFailureIsPropagatedWithoutAnAPIRequest() async {
        let log = RequestLog()
        let service = ClaudeUsageService(
            loadCredentials: { throw ClaudeUsageError.keychainReadFailed(51) },
            fetch: { request in
                log.record(request)
                return ClaudeUsageHTTPResponse(statusCode: 200, body: Self.usageBody)
            }
        )

        do {
            _ = try await service.read()
            XCTFail("Expected keychain failure")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .keychainReadFailed(51))
        }
        XCTAssertTrue(log.recordedAuthorizations.isEmpty)
    }

    func testReportsMissingAndExpiredCredentials() async {
        let missing = ClaudeUsageService(
            loadCredentials: { throw ClaudeUsageError.credentialsNotFound },
            fetch: { _ in ClaudeUsageHTTPResponse(statusCode: 200, body: Self.usageBody) }
        )
        do {
            _ = try await missing.read()
            XCTFail("Expected missing credentials")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .credentialsNotFound)
        }

        let expired = ClaudeUsageService(
            loadCredentials: { ClaudeOAuthCredentials(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1)) },
            fetch: { _ in ClaudeUsageHTTPResponse(statusCode: 200, body: Self.usageBody) }
        )
        do {
            _ = try await expired.read()
            XCTFail("Expected expired credentials")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .tokenExpired)
        }
    }

    func testDisplayStateKeepsRecentReadingThroughTransientFailures() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reading = ClaudeUsageReading(
            fiveHour: ClaudeUsageWindow(remainingPercent: 80, resetsAt: nil),
            sevenDay: nil,
            readAt: now.addingTimeInterval(-60)
        )

        XCTAssertEqual(
            ClaudeUsageDisplayState.state(afterFailure: .httpStatus(429), previous: .loaded(reading), now: now),
            .loaded(reading)
        )
        XCTAssertEqual(
            ClaudeUsageDisplayState.state(afterFailure: .unauthorized, previous: .loaded(reading), now: now),
            .failed(.unauthorized)
        )
        XCTAssertEqual(
            ClaudeUsageDisplayState.state(afterFailure: .credentialsNotFound, previous: .loaded(reading), now: now),
            .hidden
        )
        XCTAssertEqual(
            ClaudeUsageDisplayState.state(
                afterFailure: nil,
                previous: .loaded(reading),
                now: now.addingTimeInterval(ClaudeUsageDisplayState.staleReadingTolerance)
            ),
            .failed(nil)
        )
    }

    func testPresentationShowsBothWindowsAndLowestBar() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let reading = ClaudeUsageReading(
            fiveHour: ClaudeUsageWindow(remainingPercent: 82, resetsAt: Date(timeIntervalSince1970: 1_785_258_369)),
            sevenDay: ClaudeUsageWindow(remainingPercent: 64, resetsAt: Date(timeIntervalSince1970: 1_785_558_369)),
            readAt: Date()
        )

        let presentation = try XCTUnwrap(
            ClaudeUsagePresentationBuilder.presentation(
                for: .loaded(reading),
                language: .korean,
                timeZone: timeZone
            )
        )

        XCTAssertEqual(presentation.titleText, "Claude 남은 한도")
        XCTAssertEqual(presentation.valueText, "5시간 82% · 주간 64%")
        XCTAssertEqual(presentation.remainingPercent, 64)
        XCTAssertEqual(presentation.barSegments, [
            WeeklyUsageBarSegment(kind: .fiveHour, remainingPercent: 82, labelText: "5시간 82%"),
            WeeklyUsageBarSegment(kind: .sevenDay, remainingPercent: 64, labelText: "주간 64%"),
        ])
        XCTAssertTrue(presentation.detailText?.contains("초기화") == true)
        XCTAssertNil(ClaudeUsagePresentationBuilder.presentation(for: .hidden, language: .english))
        XCTAssertEqual(
            ClaudeUsagePresentationBuilder.presentation(for: .failed(.tokenExpired), language: .english)?.detailText,
            "Open Claude Desktop to refresh its sign-in"
        )
    }
}

@MainActor
final class WeeklyUsageBarSegmentTests: XCTestCase {
    func testSegmentsKeepTheirOwnColorUntilTheyRunLow() {
        func color(_ kind: WeeklyUsageBarSegment.Kind, _ percent: Int) -> NSColor {
            WeeklyUsageIndicatorView.segmentColor(
                for: WeeklyUsageBarSegment(kind: kind, remainingPercent: percent, labelText: "")
            )
        }

        XCTAssertEqual(color(.fiveHour, 82), .systemBlue)
        XCTAssertEqual(color(.sevenDay, 25), .systemPurple)
        XCTAssertEqual(color(.fiveHour, 24), .systemOrange)
        XCTAssertEqual(color(.sevenDay, 10), .systemOrange)
        XCTAssertEqual(color(.sevenDay, 9), .systemRed)
    }

    func testLegendColorsADotPerSegment() throws {
        let presentation = WeeklyUsageIndicatorPresentation(
            titleText: "Claude",
            valueText: "5h 8% · 7d 60%",
            detailText: nil,
            remainingPercent: 8,
            barSegments: [
                WeeklyUsageBarSegment(kind: .fiveHour, remainingPercent: 8, labelText: "5h 8%"),
                WeeklyUsageBarSegment(kind: .sevenDay, remainingPercent: 60, labelText: "7d 60%"),
            ]
        )

        let legend = try XCTUnwrap(
            WeeklyUsageIndicatorView.segmentLegend(
                for: presentation,
                font: .systemFont(ofSize: 13),
                textColor: .labelColor
            )
        )
        XCTAssertEqual(legend.string, "● 5h 8% · ● 7d 60%")
        XCTAssertEqual(legend.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        let secondDot = (legend.string as NSString).range(of: "●", options: .backwards).location
        XCTAssertEqual(legend.attribute(.foregroundColor, at: secondDot, effectiveRange: nil) as? NSColor, .systemPurple)

        let plain = WeeklyUsageIndicatorPresentation(titleText: "", valueText: "", detailText: nil, remainingPercent: 50)
        XCTAssertNil(WeeklyUsageIndicatorView.segmentLegend(for: plain, font: .systemFont(ofSize: 13), textColor: .labelColor))
    }
}

final class ClaudeCodeTranscriptParserTests: XCTestCase {
    private func lines(_ records: [String]) -> [Substring] {
        records.map { Substring($0) }
    }

    private let userPrompt = #"{"type":"user","cwd":"/Users/me/app","gitBranch":"main","sessionId":"s1","message":{"role":"user","content":"Fix the   login\nbug please"}}"#
    private let assistantToolUse = #"{"type":"assistant","cwd":"/Users/me/app","message":{"role":"assistant","stop_reason":null,"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
    private let toolResult = #"{"type":"user","cwd":"/Users/me/app","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private let assistantDone = #"{"type":"assistant","cwd":"/Users/me/app","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
    private let assistantStreaming = #"{"type":"assistant","cwd":"/Users/me/app","message":{"role":"assistant","stop_reason":null,"content":[{"type":"text","text":"Looking"}]}}"#

    func testPhaseFollowsNewestMainTranscriptEntry() {
        XCTAssertEqual(ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt])).phase, .working)
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, assistantToolUse])).phase,
            .working
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, assistantToolUse, toolResult])).phase,
            .working
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(
                headLines: [],
                tailLines: lines([userPrompt, assistantToolUse, toolResult, assistantDone])
            ).phase,
            .finished
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, assistantStreaming])).phase,
            .likelyWorking
        )
    }

    func testQuestionAndPlanApprovalWaitForUser() {
        let askQuestion = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t2","name":"AskUserQuestion","input":{}}]}}"#
        let planApproval = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"t3","name":"ExitPlanMode","input":{}}]}}"#
        let answer = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"User answered"}]}}"#
        let attachment = #"{"type":"attachment","isSidechain":false}"#

        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, askQuestion, attachment])).phase,
            .waitingForUser
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, planApproval])).phase,
            .waitingForUser
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, askQuestion, answer])).phase,
            .working
        )

        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.status(for: .waitingForUser, modifiedAt: modifiedAt, now: modifiedAt.addingTimeInterval(3 * 60 * 60)),
            .waitingForUser
        )
    }

    func testIgnoresSidechainAndBookkeepingEntries() {
        let sidechain = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#
        let snapshot = #"{"type":"file-history-snapshot","messageId":"m1"}"#
        let turnDuration = #"{"type":"system","subtype":"turn_duration","durationMs":1200}"#

        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([assistantDone, sidechain, snapshot])).phase,
            .finished
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([userPrompt, assistantStreaming, turnDuration])).phase,
            .finished
        )
    }

    func testInterruptedAndLocalCommandTurnsAreFinished() {
        let interrupted = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let localOutput = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to opus</local-command-stdout>"}}"#

        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([assistantToolUse, interrupted])).phase,
            .finished
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([assistantDone, localOutput])).phase,
            .finished
        )

        let systemCommand = #"{"type":"system","subtype":"local_command","isSidechain":false,"content":"<command-name>/usage</command-name>\n<command-message>usage</command-message>"}"#
        let systemOutput = #"{"type":"system","subtype":"local_command","isSidechain":false,"content":"<local-command-stdout>Settings dialog dismissed</local-command-stdout>"}"#
        let lastPrompt = #"{"type":"last-prompt","lastPrompt":"usage","sessionId":"s1"}"#
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(
                headLines: [],
                tailLines: lines([userPrompt, assistantToolUse, toolResult, systemCommand, systemOutput, lastPrompt])
            ).phase,
            .finished
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.summarize(headLines: [], tailLines: lines([systemCommand])).phase,
            .finished
        )
    }

    func testTitlePrefersCustomTitleThenSummaryThenFirstPrompt() {
        let commandPrompt = #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#
        let summaryLine = #"{"type":"summary","summary":"Login bug fix","leafUuid":"u1"}"#
        let customTitle = #"{"type":"custom-title","customTitle":"Auth cleanup","sessionId":"s1"}"#

        let promptOnly = ClaudeCodeTranscriptParser.summarize(
            headLines: lines([commandPrompt, userPrompt]),
            tailLines: lines([assistantDone])
        )
        XCTAssertEqual(promptOnly.title, "Fix the login bug please")
        XCTAssertEqual(promptOnly.projectPath, "/Users/me/app")
        XCTAssertEqual(promptOnly.gitBranch, "main")

        let summarized = ClaudeCodeTranscriptParser.summarize(
            headLines: lines([summaryLine, userPrompt]),
            tailLines: lines([assistantDone])
        )
        XCTAssertEqual(summarized.title, "Login bug fix")

        let renamed = ClaudeCodeTranscriptParser.summarize(
            headLines: lines([summaryLine, userPrompt]),
            tailLines: lines([assistantDone, customTitle])
        )
        XCTAssertEqual(renamed.title, "Auth cleanup")
    }

    func testStatusExpiresStaleTurns() {
        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = ClaudeCodeTranscriptParser.StatusPolicy(workingStaleInterval: 600, likelyWorkingGraceInterval: 45)

        XCTAssertEqual(
            ClaudeCodeTranscriptParser.status(for: .working, modifiedAt: modifiedAt, now: modifiedAt.addingTimeInterval(120), policy: policy),
            .running
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.status(for: .working, modifiedAt: modifiedAt, now: modifiedAt.addingTimeInterval(601), policy: policy),
            .idle
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.status(for: .likelyWorking, modifiedAt: modifiedAt, now: modifiedAt.addingTimeInterval(60), policy: policy),
            .idle
        )
        XCTAssertEqual(
            ClaudeCodeTranscriptParser.status(for: .finished, modifiedAt: modifiedAt, now: modifiedAt, policy: policy),
            .idle
        )
    }
}

final class ClaudeCodeSessionServiceTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeSessionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try super.tearDownWithError()
    }

    private func writeTranscript(
        project: String,
        sessionID: String,
        lines: [String],
        modifiedAt: Date
    ) throws {
        let directoryURL = rootURL.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("\(sessionID).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: fileURL.path)
    }

    func testListsRecentSessionsWithRunningFirst() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = #"{"type":"user","cwd":"/Users/me/app","message":{"role":"user","content":"Add tests"}}"#
        let done = #"{"type":"assistant","cwd":"/Users/me/app","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        let toolUse = #"{"type":"assistant","cwd":"/Users/me/api","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}"#
        let apiPrompt = #"{"type":"user","cwd":"/Users/me/api","message":{"role":"user","content":"Run the build"}}"#

        try writeTranscript(project: "-Users-me-app", sessionID: "finished-session", lines: [prompt, done], modifiedAt: now.addingTimeInterval(-30))
        try writeTranscript(project: "-Users-me-api", sessionID: "running-session", lines: [apiPrompt, toolUse], modifiedAt: now.addingTimeInterval(-120))
        try writeTranscript(project: "-Users-me-api", sessionID: "agent-subagent", lines: [apiPrompt, toolUse], modifiedAt: now)
        try writeTranscript(project: "-Users-me-old", sessionID: "old-session", lines: [prompt, done], modifiedAt: now.addingTimeInterval(-10 * 24 * 60 * 60))

        let projectsURL = rootURL!
        let service = ClaudeCodeSessionService(
            projectsDirectoryURLProvider: { projectsURL },
            desktopSessionsDirectoryURL: rootURL.appendingPathComponent("no-desktop", isDirectory: true)
        )
        let sessions = await service.recentSessions(now: now)

        XCTAssertEqual(sessions.map(\.id), ["running-session", "finished-session"])
        XCTAssertEqual(sessions.first?.status, .running)
        XCTAssertEqual(sessions.first?.title, "Run the build")
        XCTAssertEqual(sessions.first?.projectDisplayName, "api")
        XCTAssertEqual(sessions.last?.status, .idle)
        XCTAssertEqual(sessions.last?.title, "Add tests")
    }

    func testMissingProjectsDirectoryYieldsNoSessions() async {
        let missingURL = rootURL.appendingPathComponent("missing", isDirectory: true)
        let service = ClaudeCodeSessionService(
            projectsDirectoryURLProvider: { missingURL },
            desktopSessionsDirectoryURL: missingURL
        )

        let sessions = await service.recentSessions()

        XCTAssertTrue(sessions.isEmpty)
    }

    @MainActor
    func testDuplicateSessionAcrossProjectAndWorktreeUsesNewestTranscriptBeforeLimiting() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let waiting = #"{"type":"assistant","cwd":"/Users/me/app","message":{"role":"assistant","content":[{"type":"tool_use","id":"ask","name":"AskUserQuestion","input":{}}]}}"#
        let done = #"{"type":"assistant","cwd":"/Users/me/app/worktree","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        try writeTranscript(project: "-Users-me-app", sessionID: "shared", lines: [waiting], modifiedAt: now.addingTimeInterval(-120))
        try writeTranscript(project: "-Users-me-app-worktree", sessionID: "shared", lines: [done], modifiedAt: now)
        try writeTranscript(project: "-Users-me-other", sessionID: "other", lines: [done], modifiedAt: now.addingTimeInterval(-60))

        let projectsURL = rootURL!
        var configuration = ClaudeCodeSessionService.Configuration()
        configuration.maxSessions = 2
        let service = ClaudeCodeSessionService(
            projectsDirectoryURLProvider: { projectsURL },
            desktopSessionsDirectoryURL: rootURL.appendingPathComponent("no-desktop", isDirectory: true),
            configuration: configuration
        )
        let sessions = await service.recentSessions(now: now)

        XCTAssertEqual(sessions.map(\.id), ["shared", "other"])
        let shared = try XCTUnwrap(sessions.first { $0.id == "shared" })
        XCTAssertEqual(shared.status, .idle)
        XCTAssertEqual(shared.projectPath, "/Users/me/app/worktree")
        XCTAssertTrue(shared.transcriptPath?.hasSuffix("/-Users-me-app-worktree/shared.jsonl") == true)
        let rows = sessions.map { AppDelegate.claudeThreadRow(for: $0, untitledTitle: "Untitled") }
        XCTAssertEqual(ThreadNotificationPlanner.statusByThreadID(from: rows).count, 2)

        // Resuming the original copy must switch the canonical transcript on refresh.
        try writeTranscript(project: "-Users-me-app", sessionID: "shared", lines: [waiting], modifiedAt: now.addingTimeInterval(30))
        let refreshed = await service.recentSessions(now: now.addingTimeInterval(30))
        XCTAssertEqual(refreshed.map(\.id), ["shared", "other"])
        XCTAssertEqual(refreshed.first?.status, .waitingForUser)
        XCTAssertTrue(refreshed.first?.transcriptPath?.hasSuffix("/-Users-me-app/shared.jsonl") == true)
    }

    func testReopeningSessionDoesNotMoveItsActivityTime() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = #"{"type":"user","cwd":"/Users/me/app","timestamp":"2027-01-15T08:00:00.000Z","message":{"role":"user","content":"Add tests"}}"#
        let done = #"{"type":"assistant","cwd":"/Users/me/app","timestamp":"2027-01-15T08:05:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        // Claude Code appends these when the session is merely opened again.
        let bookkeeping = [
            #"{"type":"bridge-session","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"Add tests","sessionId":"s"}"#,
            #"{"type":"cost-state","sessionId":"s"}"#,
            #"{"type":"mode","mode":"auto","sessionId":"s"}"#,
        ]
        try writeTranscript(project: "-Users-me-app", sessionID: "reopened", lines: [prompt, done] + bookkeeping, modifiedAt: now)

        let projectsURL = rootURL!
        let service = ClaudeCodeSessionService(
            projectsDirectoryURLProvider: { projectsURL },
            desktopSessionsDirectoryURL: rootURL.appendingPathComponent("no-desktop", isDirectory: true)
        )
        let sessions = await service.recentSessions(now: now)
        let session = try XCTUnwrap(sessions.first)

        let lastMessageAt = ISO8601DateFormatter.withFractionalSeconds.date(from: "2027-01-15T08:05:00.000Z")
        XCTAssertEqual(session.updatedAt, lastMessageAt)
        XCTAssertNotEqual(session.updatedAt, now)
    }

    func testClaudeDesktopRecordsRenameHideArchivedAndCarryFocus() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = #"{"type":"user","cwd":"/Users/me/app","message":{"role":"user","content":"Add tests"}}"#
        let lastPrompt = #"{"type":"last-prompt","lastPrompt":"Also update the docs","sessionId":"kept"}"#
        let done = #"{"type":"assistant","cwd":"/Users/me/app","timestamp":"2027-01-15T08:00:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Done"}]}}"#
        let stopHook = #"{"type":"system","subtype":"stop_hook_summary","timestamp":"2027-01-15T08:00:01.500Z"}"#
        try writeTranscript(project: "-Users-me-app", sessionID: "kept", lines: [prompt, lastPrompt, done, stopHook], modifiedAt: now)
        try writeTranscript(project: "-Users-me-app", sessionID: "archived", lines: [prompt, done], modifiedAt: now)

        let desktopURL = rootURL.appendingPathComponent("desktop/account/org", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopURL, withIntermediateDirectories: true)
        let kept = #"{"sessionId":"local_1","cliSessionId":"kept","title":"Renamed in Desktop","isArchived":false,"lastFocusedAt":1799999000000,"lastActivityAt":1800000100000}"#
        let archived = #"{"sessionId":"local_2","cliSessionId":"archived","title":"Old","isArchived":true}"#
        try kept.write(to: desktopURL.appendingPathComponent("local_1.json"), atomically: true, encoding: .utf8)
        try archived.write(to: desktopURL.appendingPathComponent("local_2.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: desktopURL.appendingPathComponent("scheduled-tasks.json"), atomically: true, encoding: .utf8)

        let projectsURL = rootURL!
        let service = ClaudeCodeSessionService(
            projectsDirectoryURLProvider: { projectsURL },
            desktopSessionsDirectoryURL: rootURL.appendingPathComponent("desktop", isDirectory: true)
        )
        let sessions = await service.recentSessions(now: now)

        XCTAssertEqual(sessions.map(\.id), ["kept"])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.title, "Renamed in Desktop")
        XCTAssertEqual(session.preview, "Also update the docs")
        XCTAssertEqual(session.lastFocusedAt, Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertEqual(session.updatedAt, Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertEqual(session.finishedAt, ISO8601DateFormatter.withFractionalSeconds.date(from: "2027-01-15T08:00:01.500Z"))
        XCTAssertTrue(session.transcriptPath?.hasSuffix("kept.jsonl") == true)
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

final class ClaudeCodeSessionLauncherTests: XCTestCase {
    func testResumeScriptQuotesPathAndSessionID() {
        let script = ClaudeCodeSessionLauncher.resumeScript(
            sessionID: "abc-123",
            projectPath: "/Users/me/it's here"
        )

        XCTAssertTrue(script.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(script.contains("exec /bin/zsh -ilc "))
        XCTAssertTrue(script.contains("claude --resume"))
        XCTAssertTrue(script.contains("abc-123"))
        XCTAssertEqual(ClaudeCodeSessionLauncher.shellQuoted("it's"), #"'it'\''s'"#)
    }

    func testDesktopLinkUsesTranscriptIDAndFallsBackToTerminal() {
        let sessionID = "27769427-a7db-4906-81f8-a5ba97b7f30f"
        XCTAssertEqual(
            ClaudeCodeSessionLauncher.desktopResumeURL(sessionID: sessionID)?.absoluteString,
            "claude://resume?session=27769427-a7db-4906-81f8-a5ba97b7f30f"
        )
        XCTAssertNil(ClaudeCodeSessionLauncher.desktopResumeURL(sessionID: "../not-a-session"))

        XCTAssertEqual(ClaudeCodeSessionLauncher.destination(sessionID: sessionID, claudeDesktopInstalled: true), .claudeDesktop)
        XCTAssertEqual(ClaudeCodeSessionLauncher.destination(sessionID: sessionID, claudeDesktopInstalled: false), .terminal)
        XCTAssertEqual(ClaudeCodeSessionLauncher.destination(sessionID: "abc-123", claudeDesktopInstalled: true), .terminal)
    }
}

@MainActor
final class AppDelegateClaudeActivityTests: XCTestCase {
    func testClaudeSessionIdentifiersRoundTrip() {
        let identifier = AppDelegate.claudeSessionIdentifier(for: "session-1")

        XCTAssertEqual(AppDelegate.claudeSessionID(fromIdentifier: identifier), "session-1")
        XCTAssertNil(AppDelegate.claudeSessionID(fromIdentifier: "session-1"))
        XCTAssertTrue(AppDelegate.isClaudeThreadID(identifier))
        XCTAssertFalse(AppDelegate.isClaudeThreadID("codex-thread"))
    }

    private func session(
        _ id: String,
        _ status: ClaudeCodeSession.Status,
        pendingRequest: ClaudeCodeSession.PendingRequest? = nil,
        finishedAt: Date? = nil,
        lastFocusedAt: Date? = nil
    ) -> ClaudeCodeSession {
        ClaudeCodeSession(
            id: id,
            title: nil,
            projectPath: "/Users/me/app",
            gitBranch: nil,
            status: status,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            pendingRequest: pendingRequest,
            preview: "Fix the bug",
            finishedAt: finishedAt,
            transcriptPath: "/tmp/\(id).jsonl",
            lastFocusedAt: lastFocusedAt
        )
    }

    func testClaudeSessionsBecomeThreadRows() {
        let finishedAt = Date(timeIntervalSince1970: 1_799_999_000)
        let idle = AppDelegate.claudeThreadRow(for: session("a", .idle, finishedAt: finishedAt), untitledTitle: "New session")

        XCTAssertEqual(idle.id, "claude-session:a")
        XCTAssertEqual(idle.displayTitle, "New session")
        XCTAssertEqual(idle.preview, "Fix the bug")
        XCTAssertEqual(idle.cwd, "/Users/me/app")
        XCTAssertEqual(idle.sessionPath, "/tmp/a.jsonl")
        XCTAssertEqual(idle.presentationStatus, .idle)
        XCTAssertEqual(idle.lastTerminalActivityAt, finishedAt)
        XCTAssertFalse(idle.isSubagent)

        XCTAssertEqual(AppDelegate.claudeThreadRow(for: session("b", .running), untitledTitle: "").presentationStatus, .running)
        XCTAssertEqual(
            AppDelegate.claudeThreadRow(for: session("c", .waitingForUser, pendingRequest: .userInput), untitledTitle: "").displayStatus,
            .waitingForInput
        )
        XCTAssertEqual(
            AppDelegate.claudeThreadRow(for: session("d", .waitingForUser, pendingRequest: .approval), untitledTitle: "").displayStatus,
            .needsApproval
        )
    }

    func testLatestFocusedSessionCountsAsViewedOnlyWhileClaudeDesktopIsFrontmost() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = [
            session("older", .idle, lastFocusedAt: now.addingTimeInterval(-600)),
            session("latest", .idle, lastFocusedAt: now.addingTimeInterval(-60)),
            session("cli-only", .idle),
        ]

        let frontmost = AppDelegate.claudeViewedAtByThreadID(sessions: sessions, claudeDesktopIsFrontmost: true, now: now)
        XCTAssertEqual(frontmost["claude-session:latest"], now)
        XCTAssertEqual(frontmost["claude-session:older"], now.addingTimeInterval(-600))
        XCTAssertNil(frontmost["claude-session:cli-only"])

        let background = AppDelegate.claudeViewedAtByThreadID(sessions: sessions, claudeDesktopIsFrontmost: false, now: now)
        XCTAssertEqual(background["claude-session:latest"], now.addingTimeInterval(-60))
    }

    func testClaudeBadgeIsStyledInMenuTitle() {
        let title = AppDelegate.claudeBadgedMenuTitle("Fix login | Claude · 3 min ago")
        let badgeLocation = ("Fix login | Claude · 3 min ago" as NSString).range(of: "Claude").location

        XCTAssertEqual(title.string, "Fix login | Claude · 3 min ago")
        XCTAssertEqual(title.attribute(.foregroundColor, at: badgeLocation, effectiveRange: nil) as? NSColor, AppDelegate.claudeBadgeColor)
        XCTAssertNil(title.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testOptionNavigationJumpsBetweenSectionsThenSettings() {
        let navigation = AppDelegate.optionNavigationState(
            sectionIdentifiers: [["pinned-1", "pinned-2"], [], ["recent-1", "claude-session:a"]],
            settingsIdentifier: "settings"
        )

        XCTAssertEqual(navigation.targetIDs, ["pinned-1", "recent-1", "settings"])
        XCTAssertEqual(navigation.sectionIndexByIdentifier["pinned-2"], 0)
        XCTAssertEqual(navigation.sectionIndexByIdentifier["claude-session:a"], 1)
        XCTAssertEqual(navigation.sectionIndexByIdentifier["settings"], 2)
        XCTAssertEqual(
            AppDelegate.projectShortcutIdentifiers(sectionFirstIdentifiers: ["pinned-1", "claude-session:a"]),
            ["pinned-1", "claude-session:a"]
        )
    }
}

final class AttentionRotationTests: XCTestCase {
    func testCurrentWaitingChatIsSkippedButUnreadIsNot() {
        XCTAssertNil(AttentionRotation.next(orderedIDs: ["a"], waitingIDs: ["a"], unreadIDs: [], currentID: "a"))
        XCTAssertEqual(AttentionRotation.next(orderedIDs: ["a"], waitingIDs: [], unreadIDs: ["a"], currentID: "a"), "a")
        XCTAssertNil(AttentionRotation.next(orderedIDs: [], waitingIDs: [], unreadIDs: [], currentID: nil))
        XCTAssertEqual(
            AttentionRotation.next(
                orderedIDs: ["codex-a", "claude-session:b", "codex-c"],
                waitingIDs: ["claude-session:b"],
                unreadIDs: ["codex-c"],
                currentID: "claude-session:b"
            ),
            "codex-c"
        )
    }
}
