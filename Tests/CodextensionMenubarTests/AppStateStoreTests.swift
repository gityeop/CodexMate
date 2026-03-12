import XCTest
@testable import CodextensionMenubar

final class AppStateStoreTests: XCTestCase {
    func testCodexThreadDeeplinkUsesDesktopRouteFormat() {
        let url = CodexDeepLink.threadURL(threadID: "123e4567-e89b-12d3-a456-426614174000")

        XCTAssertEqual(url?.absoluteString, "codex://threads/123e4567-e89b-12d3-a456-426614174000")
    }

    func testReplaceRecentThreadsSortsNewestFirst() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "older", updatedAt: 100, status: .idle),
            thread(id: "newer", updatedAt: 200, status: .idle),
        ])

        XCTAssertEqual(store.recentThreads.map(\.id), ["newer", "older"])
    }

    func testProjectSectionsGroupThreadsBySavedWorkspaceRoot() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, cwd: "/Users/tester/notion-blog/posts"),
            thread(id: "thread-2", updatedAt: 200, status: .active(flags: []), cwd: "/Users/tester/Maccy/Sources"),
            thread(id: "thread-3", updatedAt: 150, status: .idle, cwd: "/Users/tester/notion-blog/scripts")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/Users/tester/notion-blog", displayName: "notion-blog"),
            .init(path: "/Users/tester/Maccy", displayName: "Maccy")
        ])

        let sections = store.projectSections(using: catalog)

        XCTAssertEqual(sections.map(\.displayName), ["Maccy", "notion-blog"])
        XCTAssertEqual(sections[0].threads.map(\.id), ["thread-2"])
        XCTAssertEqual(sections[1].threads.map(\.id), ["thread-3", "thread-1"])
    }

    func testProjectSectionsFallBackToFolderNameForUnmatchedCWD() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, cwd: "/tmp/scratch-area")
        ])

        let sections = store.projectSections(using: .empty)

        XCTAssertEqual(sections.map(\.id), ["/tmp/scratch-area"])
        XCTAssertEqual(sections.map(\.displayName), ["scratch-area"])
    }

    func testProjectSectionsLimitToFiveProjectsAndEightThreads() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "a-1", updatedAt: 120, status: .idle, cwd: "/tmp/A/one"),
            thread(id: "a-2", updatedAt: 119, status: .idle, cwd: "/tmp/A/two"),
            thread(id: "b-1", updatedAt: 118, status: .idle, cwd: "/tmp/B/one"),
            thread(id: "c-1", updatedAt: 117, status: .idle, cwd: "/tmp/C/one"),
            thread(id: "d-1", updatedAt: 116, status: .idle, cwd: "/tmp/D/one"),
            thread(id: "e-1", updatedAt: 115, status: .idle, cwd: "/tmp/E/one"),
            thread(id: "f-1", updatedAt: 114, status: .idle, cwd: "/tmp/F/one"),
            thread(id: "a-3", updatedAt: 113, status: .idle, cwd: "/tmp/A/three"),
            thread(id: "b-2", updatedAt: 112, status: .idle, cwd: "/tmp/B/two"),
            thread(id: "c-2", updatedAt: 111, status: .idle, cwd: "/tmp/C/two"),
            thread(id: "a-4", updatedAt: 110, status: .idle, cwd: "/tmp/A/four")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B"),
            .init(path: "/tmp/C", displayName: "C"),
            .init(path: "/tmp/D", displayName: "D"),
            .init(path: "/tmp/E", displayName: "E"),
            .init(path: "/tmp/F", displayName: "F")
        ])

        let sections = store.projectSections(using: catalog, maxProjects: 5, maxThreads: 8)

        XCTAssertEqual(sections.map(\.displayName), ["A", "B", "C", "D", "E"])
        XCTAssertEqual(sections.reduce(0) { $0 + $1.threads.count }, 8)
        XCTAssertEqual(sections[0].threads.map(\.id), ["a-1", "a-2", "a-3"])
        XCTAssertEqual(sections[1].threads.map(\.id), ["b-1", "b-2"])
        XCTAssertEqual(sections[2].threads.map(\.id), ["c-1"])
        XCTAssertEqual(sections[3].threads.map(\.id), ["d-1"])
        XCTAssertEqual(sections[4].threads.map(\.id), ["e-1"])
    }

    func testProjectSectionsPrioritizeFailedProjectWithinVisibleLimits() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "a-1", updatedAt: 120, status: .idle, cwd: "/tmp/A/one"),
            thread(id: "b-1", updatedAt: 119, status: .idle, cwd: "/tmp/B/one"),
            thread(id: "c-1", updatedAt: 118, status: .idle, cwd: "/tmp/C/one"),
            thread(id: "d-1", updatedAt: 117, status: .idle, cwd: "/tmp/D/one"),
            thread(id: "e-1", updatedAt: 116, status: .idle, cwd: "/tmp/E/one"),
            thread(id: "f-failed", updatedAt: 115, status: .systemError, cwd: "/tmp/F/one")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B"),
            .init(path: "/tmp/C", displayName: "C"),
            .init(path: "/tmp/D", displayName: "D"),
            .init(path: "/tmp/E", displayName: "E"),
            .init(path: "/tmp/F", displayName: "F")
        ])

        let sections = store.projectSections(using: catalog, maxProjects: 5, maxThreads: 8)

        XCTAssertEqual(sections.map(\.displayName), ["A", "B", "C", "D", "F"])
        XCTAssertEqual(sections.last?.threads.map(\.id), ["f-failed"])
    }

    func testProjectCatalogLongestPrefixMatchUsesDeepestRoot() {
        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/Users/tester/notion-blog", displayName: "notion-blog"),
            .init(path: "/Users/tester/notion-blog/apps/web", displayName: "web")
        ])

        let project = catalog.project(for: "/Users/tester/notion-blog/apps/web/pages")

        XCTAssertEqual(project.id, "/Users/tester/notion-blog/apps/web")
        XCTAssertEqual(project.displayName, "web")
    }

    func testThreadStatusIconsMatchMenuGlyphs() {
        XCTAssertEqual(AppStateStore.ThreadStatus.waitingForInput.icon, "💬")
        XCTAssertEqual(AppStateStore.ThreadStatus.needsApproval.icon, "🟡")
        XCTAssertEqual(AppStateStore.ThreadStatus.running.icon, "⏳")
        XCTAssertEqual(AppStateStore.ThreadStatus.idle.icon, "✅")
        XCTAssertEqual(AppStateStore.ThreadStatus.notLoaded.icon, "◌")
        XCTAssertEqual(AppStateStore.ThreadStatus.failed(message: nil).icon, "⚠️")
    }

    func testTurnStartedMarksThreadRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
    }

    func testThreadListRefreshKeepsWatchedActiveTurnRunningWhenIncomingIdle() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .idle)
        ])

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.activeTurnID, "turn-1")
    }

    func testDesktopRunningOverlayUpdatesUnwatchedThread() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.recentThreads.first?.statusUpdatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testReplaceRecentThreadsPreservesNewerRunningOverlayAgainstStaleIdlePayload() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 150, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.recentThreads.first?.statusUpdatedAt, Date(timeIntervalSince1970: 200))
    }

    func testReplaceRecentThreadsClearsRunningOverlayWhenIncomingIdlePayloadIsNewer() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 250, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 250))
    }

    func testDesktopPendingOverlayUpdatesUnwatchedThreadFromNotLoaded() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                waitingForInputThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testDesktopFailureOverlayUpdatesUnwatchedThreadFromNotLoaded() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                failedThreads: [
                    "thread-1": .init(
                        message: "Turn error: stream disconnected before completion",
                        loggedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            store.recentThreads.first?.status,
            .failed(message: "Turn error: stream disconnected before completion")
        )
    }

    func testDesktopRunningOverlayBeatsFailureOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"],
                failedThreads: [
                    "thread-1": .init(
                        message: "Turn error: stream disconnected before completion",
                        loggedAt: Date(timeIntervalSince1970: 200)
                    )
                ]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .running)
    }

    func testDesktopSnapshotClearsUnwatchedWaitingWhenPendingDisappears() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                waitingForInputThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                waitingForInputThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .notLoaded)
        XCTAssertEqual(store.lastDiagnostic, "cleared stale pending thread=thread-1 from=Waiting for input to=Not loaded via desktop snapshot")
    }

    func testUserInputRequestMarksWaitingForInput() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .waitingForInput)
    }

    func testServerRequestResolvedClearsWaitingForInputToRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(notification: .serverRequestResolved(
            ServerRequestResolvedNotification(threadId: "thread-1")
        ))

        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
    }

    func testActiveFlagWaitingOnUserInputMapsToWaitingForInput() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .active(flags: [.waitingOnUserInput]))
        ])

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testActiveFlagWaitingOnApprovalMapsToNeedsApproval() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .active(flags: [.waitingOnApproval]))
        ])

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
    }

    func testDesktopRunningOverlayClearsStaleWaitingForInputWhenPendingEvidenceDisappears() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .waitingForInput)
    }

    func testDesktopRunningOverlayClearsStaleNeedsApprovalWhenPendingEvidenceDisappears() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .approval(
            ApprovalRequestPayload(threadId: "thread-1", turnId: "turn-1", itemId: "item-1", reason: nil)
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .needsApproval)
    }

    func testDesktopActiveTurnCountKeepsOverallRunningWithoutThreadOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: []
            )
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.summaryText, "Recent 1 | Watching 0 | Running 1 | Reply 0 | Approval 0")
    }

    func testDesktopSnapshotDoesNotClearWatchedActiveTurnWithoutRunningEvidence() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.activeTurnID, "turn-1")
    }

    func testDesktopCompletionHintClearsWatchedRunningThreadAndAggregateFallback() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.apply(desktopCompletionHints: [
            "thread-1": Date(timeIntervalSince1970: 300)
        ])

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 300))
    }

    func testDesktopCompletionHintClearsUnwatchedRunningOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.apply(desktopCompletionHints: [
            "thread-1": Date(timeIntervalSince1970: 300)
        ])

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 300))
    }

    func testDesktopRunningOverlayPromotesWatchedIdleThreadWhenFreshEvidenceAppears() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
    }

    func testThreadListRefreshPreservesWatchedRuntimeStatusWhenIncomingPayloadIsStale() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 90, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertTrue(store.recentThreads.first?.isWatched ?? false)
    }

    func testMarkWatchedPreservesNewerRuntimeStatusWhenResumePayloadIsStale() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.markWatched(thread: thread(id: "thread-1", updatedAt: 150, status: .idle))

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 150))
        XCTAssertEqual(store.recentThreads.first?.statusUpdatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNotNil(store.recentThreads.first?.activeTurnID)
    }

    func testThreadListRefreshClearsWatchedRunningThreadWhenIncomingIdleIsNewer() {
        var store = AppStateStore()

        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 250, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
    }

    func testDesktopPendingOverlayDoesNotAdvanceDisplayUpdatedAt() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                waitingForInputThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.recentThreads.first?.statusUpdatedAt, Date(timeIntervalSince1970: 200))
    }

    func testThreadListRefreshClearsWatchedWaitingForInputWhenIncomingIdleIsNewer() {
        var store = AppStateStore()
        let newerUpdatedAt = Int(Date().addingTimeInterval(60).timeIntervalSince1970)
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: newerUpdatedAt, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
    }

    func testThreadListRefreshClearsWatchedWaitingForInputWhenIncomingNotLoadedIsNewer() {
        var store = AppStateStore()
        let newerUpdatedAt = Int(Date().addingTimeInterval(60).timeIntervalSince1970)
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: newerUpdatedAt, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .notLoaded)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .notLoaded)
    }

    func testThreadListRefreshClearsWatchedNeedsApprovalWhenIncomingIdleIsNewer() {
        var store = AppStateStore()
        let newerUpdatedAt = Int(Date().addingTimeInterval(60).timeIntervalSince1970)
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .approval(
            ApprovalRequestPayload(threadId: "thread-1", turnId: "turn-1", itemId: "item-1", reason: nil)
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: newerUpdatedAt, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
    }

    func testDesktopSnapshotDoesNotOverrideWatchedWaitingWhenRunningEvidenceAppears() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.listedStatus, .notLoaded)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .waitingForInput)
        XCTAssertEqual(store.overallStatus, .waitingForUser)
    }

    func testDesktopSnapshotDoesNotOverrideWatchedWaitingWhenPendingDisappears() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.listedStatus, .notLoaded)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .waitingForInput)
        XCTAssertEqual(store.overallStatus, .waitingForUser)
    }

    func testWaitingForInputBeatsRunningInOverallStatus() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 100, status: .active(flags: [])),
            thread(id: "waiting", updatedAt: 200, status: .active(flags: [.waitingOnUserInput]))
        ])

        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.overallStatus.icon, "💬")
    }

    func testTurnCompletedClearsWaitingForInputToIdle() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNotNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testWatchedThreadTransitionsFromRunningToWaitingToRunningToUnreadAfterCompletion() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))
        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)

        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))
        XCTAssertEqual(store.overallStatus, .waitingForUser)
        XCTAssertEqual(store.recentThreads.first?.presentationStatus, .waitingForUser)

        store.apply(notification: .serverRequestResolved(
            ServerRequestResolvedNotification(threadId: "thread-1")
        ))
        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNotNil(store.recentThreads.first?.lastTerminalActivityAt)
        XCTAssertEqual(
            MenubarStatusPresentation.statusItemIcon(overallStatus: store.overallStatus, hasUnreadThreads: true),
            "🔵"
        )
    }

    func testThreadListRefreshClearsWatchedRunningThreadWhenIncomingFailureIsNewer() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 250, status: .systemError)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: nil))
        XCTAssertEqual(store.recentThreads.first?.presentationStatus, .failed)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
    }

    func testTurnFailureClearsWaitingForInputToFailed() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(
                    id: "turn-1",
                    status: .failed,
                    error: CodexTurnError(message: "boom")
                )
            )
        ))

        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: "boom"))
        XCTAssertNotNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testTurnFailureMarksThreadFailed() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(
                    id: "turn-1",
                    status: .failed,
                    error: CodexTurnError(message: "boom")
                )
            )
        ))

        XCTAssertEqual(store.overallStatus, .failed)
        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: "boom"))
        XCTAssertNotNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testServerRequestDoesNotSetLastTerminalActivityAt() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        XCTAssertNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testThreadListRefreshDoesNotSetLastTerminalActivityAtFromUpdatedAtOnly() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 120, status: .active(flags: []))
        ])

        XCTAssertNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testMarkWatchedIdleInfersLastTerminalActivityAt() {
        var store = AppStateStore()

        store.markWatched(thread: thread(id: "thread-1", updatedAt: 120, status: .idle))

        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 120))
    }

    func testErrorNotificationClearsActiveTurnAndRecordsLastTerminalActivityAt() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.apply(notification: .error(
            ErrorNotificationPayload(
                error: CodexTurnError(message: "boom"),
                willRetry: false,
                threadId: "thread-1",
                turnId: "turn-1"
            )
        ))

        XCTAssertEqual(store.overallStatus, .failed)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .failed(message: "boom"))
        XCTAssertNotNil(store.recentThreads.first?.lastTerminalActivityAt)
    }

    func testUnwatchedSystemErrorMarksOverallFailed() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle),
            thread(id: "thread-2", updatedAt: 200, status: .systemError)
        ])

        XCTAssertEqual(store.overallStatus, .failed)
        XCTAssertEqual(store.recentThreads.first?.status, .failed(message: nil))
    }

    func testFailedThreadsReturnsNewestFailuresFirst() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "idle", updatedAt: 100, status: .idle),
            thread(id: "failed-old", updatedAt: 150, status: .systemError),
            thread(id: "failed-new", updatedAt: 200, status: .systemError)
        ])

        XCTAssertEqual(store.failedThreads.map(\.id), ["failed-new", "failed-old"])
    }

    private func thread(id: String, updatedAt: Int, status: CodexThreadStatus, cwd: String? = nil) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt - 10,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd ?? "/tmp/\(id)",
            name: nil
        )
    }
}
