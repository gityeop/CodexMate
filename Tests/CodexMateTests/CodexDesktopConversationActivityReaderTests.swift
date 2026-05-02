import XCTest
@testable import CodexMate

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
        2026-03-11T12:21:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-7 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/archive originWebcontentsId=1 requestId=h targetDestroyed=false
        2026-03-11T12:21:30.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-8 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/archive originWebcontentsId=1 requestId=i targetDestroyed=false
        2026-03-11T12:22:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-8 durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/unarchive originWebcontentsId=1 requestId=j targetDestroyed=false
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
        XCTAssertNil(snapshot.latestTurnCompletedAtByThreadID["thread-1"])
        XCTAssertNil(snapshot.latestTurnCompletedAtByThreadID["thread-2"])
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-3"], date("2026-03-11T12:20:30.000Z"))
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-4"])
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-5"])
        XCTAssertNil(snapshot.latestTurnStartedAtByThreadID["thread-6"])
        XCTAssertEqual(snapshot.latestArchiveRequestedAtByThreadID["thread-7"], date("2026-03-11T12:21:00.000Z"))
        XCTAssertEqual(snapshot.latestArchiveRequestedAtByThreadID["thread-8"], date("2026-03-11T12:21:30.000Z"))
        XCTAssertEqual(snapshot.latestUnarchiveRequestedAtByThreadID["thread-8"], date("2026-03-11T12:22:00.000Z"))
    }

    func testActivitySnapshotDoesNotTreatMaybeResumeSuccessAsTurnCompletion() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "resume.log")
        try """
        2026-03-11T12:17:11.346Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false
        2026-03-11T12:17:11.351Z info [electron-message-handler] maybe_resume_success conversationId=thread-1 latestTurnId=turn-1 latestTurnStatus=completed markedStreaming=true turnCount=22
        2026-03-11T12:20:30.000Z info [electron-message-handler] [desktop-notifications] show turn-complete conversationId=thread-2 turnId=turn-b
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-1"], date("2026-03-11T12:17:11.346Z"))
        XCTAssertNil(snapshot.latestTurnCompletedAtByThreadID["thread-1"])
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-2"], date("2026-03-11T12:20:30.000Z"))
    }

    func testActivitySnapshotParsesAppServerTurnCompletedLogs() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "app-server.log")
        try """
        2026-03-11T12:17:12.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=turn/start originWebcontentsId=1 requestId=b targetDestroyed=false
        2026-03-11T12:17:13.000Z info [codex_app_server::outgoing_message] app-server event: turn/completed thread_id=thread-1
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestTurnStartedAtByThreadID["thread-1"], date("2026-03-11T12:17:12.000Z"))
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-1"], date("2026-03-11T12:17:13.000Z"))
    }

    func testActivitySnapshotTreatsTurnInterruptAsCompletionHint() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "interrupt.log")
        try """
        2026-03-11T12:17:12.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=turn/start originWebcontentsId=1 requestId=a targetDestroyed=false
        2026-03-11T12:17:16.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=2 errorCode=null hadInternalHandler=false hadPending=true method=turn/interrupt originWebcontentsId=1 requestId=b targetDestroyed=false
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestTurnStartedAtByThreadID["thread-1"], date("2026-03-11T12:17:12.000Z"))
        XCTAssertEqual(snapshot.latestTurnCompletedAtByThreadID["thread-1"], date("2026-03-11T12:17:16.000Z"))
    }

    func testActivitySnapshotIncrementallyParsesAppendedLogData() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "incremental.log")
        try """
        2026-03-11T12:17:11.346Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false

        """.write(to: logURL, atomically: true, encoding: .utf8)

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2,
            recentLogFileCacheLifetime: 60
        )

        let firstSnapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )
        XCTAssertEqual(firstSnapshot.latestViewedAtByThreadID["thread-1"], date("2026-03-11T12:17:11.346Z"))

        let appendedData = """
        2026-03-11T12:17:12.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-2 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=turn/start originWebcontentsId=1 requestId=b targetDestroyed=false
        2026-03-11T12:17:13.000Z info [electron-message-handler] [desktop-notifications] show turn-complete conversationId=thread-2 turnId=turn-1
        2026-03-11T12:17:14.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-2 durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=thread/archive originWebcontentsId=1 requestId=c targetDestroyed=false
        """
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(appendedData.utf8))
            handle.closeFile()
        } else {
            XCTFail("Unable to open log file for appending")
        }

        let secondSnapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )
        XCTAssertEqual(secondSnapshot.latestViewedAtByThreadID["thread-2"], date("2026-03-11T12:17:14.000Z"))
        XCTAssertEqual(secondSnapshot.latestTurnStartedAtByThreadID["thread-2"], date("2026-03-11T12:17:12.000Z"))
        XCTAssertEqual(secondSnapshot.latestTurnCompletedAtByThreadID["thread-2"], date("2026-03-11T12:17:13.000Z"))
        XCTAssertEqual(secondSnapshot.latestArchiveRequestedAtByThreadID["thread-2"], date("2026-03-11T12:17:14.000Z"))
    }

    func testActivitySnapshotWaitsForCompletedTrailingLineBeforeParsing() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "partial.log")
        try "2026-03-11T12:17:11.346Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-1".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 2,
            recentLogFileCacheLifetime: 60
        )

        let firstSnapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )
        XCTAssertNil(firstSnapshot.latestViewedAtByThreadID["thread-1"])

        let appendedData = " durationMs=157 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(appendedData.utf8))
            handle.closeFile()
        } else {
            XCTFail("Unable to open log file for appending")
        }

        let secondSnapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )
        XCTAssertEqual(secondSnapshot.latestViewedAtByThreadID["thread-1"], date("2026-03-11T12:17:11.346Z"))
    }

    func testActivitySnapshotPrefersRecentlyModifiedLogsWhenAvailable() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let recentLogDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "11")
        let staleLogDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "09")
        try FileManager.default.createDirectory(at: recentLogDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staleLogDirectoryURL, withIntermediateDirectories: true)

        let recentLogURL = recentLogDirectoryURL.appending(path: "recent.log")
        try """
        2026-03-11T11:58:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-recent durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false
        """.write(to: recentLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-03-11T11:58:30.000Z") as Any],
            ofItemAtPath: recentLogURL.path
        )

        let staleLogURL = staleLogDirectoryURL.appending(path: "stale.log")
        try """
        2026-03-09T08:15:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-stale durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=b targetDestroyed=false
        """.write(to: staleLogURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-03-09T08:15:30.000Z") as Any],
            ofItemAtPath: staleLogURL.path
        )

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 3
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-recent"], date("2026-03-11T11:58:00.000Z"))
        XCTAssertNil(snapshot.latestViewedAtByThreadID["thread-stale"])
    }

    func testActivitySnapshotFallsBackToOlderLogsWhenNoRecentFilesExist() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "03")
            .appending(path: "09")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "older.log")
        try """
        2026-03-09T08:15:00.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-older durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=thread/resume originWebcontentsId=1 requestId=a targetDestroyed=false
        """.write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-03-09T08:15:30.000Z") as Any],
            ofItemAtPath: logURL.path
        )

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 3
        )

        let snapshot = reader.activitySnapshot(
            now: Date(timeIntervalSince1970: 1_773_195_200)
        )

        XCTAssertEqual(snapshot.latestViewedAtByThreadID["thread-older"], date("2026-03-09T08:15:00.000Z"))
    }

    func testActivitySnapshotUsesUTCLogDirectoryDate() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        let logDirectoryURL = tempDirectoryURL
            .appending(path: "2026")
            .appending(path: "04")
            .appending(path: "26")
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        let logURL = logDirectoryURL.appending(path: "utc-boundary.log")
        try """
        2026-04-26T16:59:30.000Z info [ElectronAppServerConnection] response_routed broadcastFallback=false conversationId=thread-utc durationMs=1 errorCode=null hadInternalHandler=false hadPending=true method=turn/start originWebcontentsId=1 requestId=a targetDestroyed=false
        """.write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-04-26T16:59:30.000Z") as Any],
            ofItemAtPath: logURL.path
        )

        let reader = CodexDesktopConversationActivityReader(
            logsDirectoryURL: tempDirectoryURL,
            lookbackDays: 1
        )

        let snapshot = reader.activitySnapshot(
            now: date("2026-04-26T17:00:00.000Z")!
        )

        XCTAssertEqual(snapshot.latestTurnStartedAtByThreadID["thread-utc"], date("2026-04-26T16:59:30.000Z"))
    }

    private func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
