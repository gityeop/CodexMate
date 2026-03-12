import XCTest
@testable import CodextensionMenubar

final class CodexDesktopConversationActivityReaderTests: XCTestCase {
    func testLatestViewedAtByThreadIDParsesRecentConversationScopedResponseRoutedEvents() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let firstLogURL = logDirectoryURL.appending(path: "first.log")
        try """
        2026-03-11T12:09:13.219Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=87 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false
        2026-03-11T12:09:16.169Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-2 durationMs=83 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=b targetDestroyed=false
        2026-03-11T12:09:20.000Z info [electron-message-handler] maybe_resume_success conversationId=thread-2 latestTurnId=turn-a latestTurnStatus=completed markedStreaming=true turnCount=4
        """.write(to: firstLogURL, atomically: true, encoding: .utf8)

        let secondLogURL = logDirectoryURL.appending(path: "second.log")
        try """
        2026-03-11T12:17:11.346Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=c targetDestroyed=false
        2026-03-11T12:17:11.351Z info [electron-message-handler] maybe_resume_success conversationId=thread-1 latestTurnId=turn-1 latestTurnStatus=completed markedStreaming=true turnCount=22
        2026-03-11T12:18:00.932Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=null durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=d targetDestroyed=false
        2026-03-11T12:19:13.511Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-3 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=turn/start originWebcontentsId=1 requestId=e targetDestroyed=false
        2026-03-11T12:20:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-4 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/metadata/update originWebcontentsId=1 requestId=f targetDestroyed=false
        2026-03-11T12:20:01.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-5 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/name/set originWebcontentsId=1 requestId=g targetDestroyed=false
        2026-03-11T12:20:02.000Z info [electron-message-handler] Conversation created conversationId=thread-6
        2026-03-11T12:20:30.000Z info [electron-message-handler] [desktop-notifications] show turn-complete conversationId=thread-3 turnId=turn-b
        """.write(to: secondLogURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-1"], date("2026-03-11T12:17:11.346Z"))
        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-2"], date("2026-03-11T12:09:16.169Z"))
        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-3"], date("2026-03-11T12:19:13.511Z"))
        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-4"], date("2026-03-11T12:20:00.000Z"))
        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-5"], date("2026-03-11T12:20:01.000Z"))
        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-6"], date("2026-03-11T12:20:02.000Z"))
        XCTAssertEqual(snapshot.latestTurnStartedAtByThreadID["thread-3"], date("2026-03-11T12:19:13.511Z"))
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-2"], date("2026-03-11T12:09:20.000Z"))
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-3"], date("2026-03-11T12:20:30.000Z"))
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-4"])
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-5"])
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-6"])
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
