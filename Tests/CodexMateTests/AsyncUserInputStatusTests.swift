import XCTest
@testable import CodexMate

final class AsyncUserInputStatusTests: XCTestCase {
    private let started = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","collaboration_mode_kind":"default"}}"#
    private let question = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"question-1","arguments":"{\"questions\":[{\"title\":\"Which account?\"}]}"}}"#
    private let accepted = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question-1","output":"{\"accepted\":true}"}}"#

    func testAsyncQuestionStaysWaitingAfterAcceptanceAndReturnsToRunningWhenWorkResumes() throws {
        try assertTransitions([
            (started, false, true),
            (question, true, true),
            (#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","delivery":"async","questions":[{"title":"Which account?"}]}}}"#, true, true),
            (accepted, true, true),
            (#"{"type":"event_msg","payload":{"type":"token_count"}}"#, true, true),
            (#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"background-1","output":"done"}}"#, true, true),
            (#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"work-1","input":"text(await tools.exec_command({cmd: 'pwd'}));"}}"#, false, true),
            (question, true, true),
            (accepted, true, true),
            (#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"work-2","arguments":"{}"}}"#, false, true),
            (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","completed_at":2000000010}}"#, false, false),
        ])
    }

    func testAsyncQuestionClearsAfterReplyAssistantMessageOrTurnBoundary() throws {
        let resolutions: [(String, Bool)] = [
            (#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Use my account."}]}}"#, true),
            (#"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"commentary","content":[{"type":"output_text","text":"Continuing with the current setting."}]}}"#, true),
            (#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2","collaboration_mode_kind":"default"}}"#, true),
            (#"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1"}}"#, false),
            (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#, false),
        ]
        for (resolution, active) in resolutions {
            try assertTransitions([
                (started, false, true), (question, true, true), (accepted, true, true),
                (resolution, false, active),
            ])
        }
    }

    func testSynchronousQuestionStillWaitsForItsOwnAnswerOrSkip() throws {
        try assertTransitions([
            (started, false, true),
            (#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"sync-1","arguments":"{}"}}"#, true, true),
            (#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"work-1","input":"text('work');"}}"#, true, true),
            (#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"sync-1","output":"{\"answers\":{}}"}}"#, false, true),
        ])
    }

    // Check a full replay, a fresh launch's reverse scan, and live incremental reads
    // at every boundary, including the exact acceptance-before-work sequence.
    private func assertTransitions(
        _ steps: [(line: String, waiting: Bool, active: Bool)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appending(path: "session.jsonl")
        try Data().write(to: sessionURL)
        let reader = CodexDesktopStateReader()
        var contents = ""
        var store = AppStateStore()
        store.markWatched(thread: CodexThread(
            id: "thread-1", preview: "Async question", createdAt: 0, updatedAt: 0,
            status: .idle, cwd: directory.path, name: nil, path: sessionURL.path, source: nil
        ))

        for (index, step) in steps.enumerated() {
            contents += step.line + "\n"
            let handle = try FileHandle(forWritingTo: sessionURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((step.line + "\n").utf8))
            try handle.close()

            let replay = CodexDesktopStateReader.parseSessionPendingState(from: contents)
            XCTAssertEqual(replay.waitingForInput, step.waiting, step.line, file: file, line: line)
            XCTAssertEqual(replay.hasActiveTask, step.active, step.line, file: file, line: line)
            XCTAssertEqual(reader.sessionPendingState(forSessionFileAt: sessionURL), replay, "Incremental: \(step.line)", file: file, line: line)
            XCTAssertEqual(CodexDesktopStateReader().sessionPendingState(forSessionFileAt: sessionURL), replay, "Cold: \(step.line)", file: file, line: line)

            let running: Set<String> = replay.hasActiveTask && !replay.waitingForInput ? ["thread-1"] : []
            store.apply(connectedDesktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: replay.hasActiveTask ? 1 : 0,
                runningThreadIDs: running,
                sessionBackedRunningThreadIDs: running,
                waitingForInputThreadIDs: replay.waitingForInput ? ["thread-1"] : [],
                latestTurnCompletedAtByThreadID: replay.latestTaskCompletedAt.map { ["thread-1": $0] } ?? [:]
            ), observedAt: Date(timeIntervalSince1970: 2_000_000_000 + Double(index)))
            if let completedAt = replay.latestTaskCompletedAt {
                store.apply(desktopCompletionHints: ["thread-1": completedAt])
            }
            let icon = step.waiting ? "💬" : step.active ? "⏳" : "✅"
            XCTAssertEqual(store.recentThreads.first?.displayStatus.icon, icon, "Row: \(step.line)", file: file, line: line)
            XCTAssertEqual(MenubarStatusPresentation.statusItemIcon(
                overallStatus: store.overallStatus, hasUnreadThreads: false
            ), icon, "Menu bar: \(step.line)", file: file, line: line)
        }
    }
}
