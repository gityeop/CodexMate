import XCTest
@testable import CodexMate

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

    func testRecentThreadsPromoteLatestRuntimeActivityFirst() {
        var store = AppStateStore()

        store.replaceRecentThreads(with: [
            thread(id: "older", updatedAt: 100, status: .idle),
            thread(id: "newer", updatedAt: 200, status: .idle),
        ])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["older"]
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(store.recentThreads.map(\.id), ["older", "newer"])
    }

    func testProjectSectionsGroupThreadsBySavedWorkspaceRoot() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, cwd: "/Users/tester/workspaces/notion-blog/posts"),
            thread(id: "thread-2", updatedAt: 200, status: .active(flags: []), cwd: "/Users/tester/workspaces/Maccy/Sources"),
            thread(id: "thread-3", updatedAt: 150, status: .idle, cwd: "/Users/tester/workspaces/notion-blog/scripts")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/Users/tester/workspaces/notion-blog", displayName: "notion-blog"),
            .init(path: "/Users/tester/workspaces/Maccy", displayName: "Maccy")
        ])

        let sections = store.projectSections(using: catalog)

        XCTAssertEqual(sections.map(\.displayName), ["Maccy", "notion-blog"])
        XCTAssertEqual(sections[0].threads.map(\.id), ["thread-2"])
        XCTAssertEqual(sections[1].threads.map(\.id), ["thread-3", "thread-1"])
    }

    func testProjectSectionsPromoteLatestRuntimeActivityProjectFirst() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-a", updatedAt: 200, status: .idle, cwd: "/tmp/A/work"),
            thread(id: "thread-b", updatedAt: 100, status: .idle, cwd: "/tmp/B/work")
        ])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-b"]
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B")
        ])

        let sections = store.projectSections(using: catalog)

        XCTAssertEqual(sections.map(\.displayName), ["B", "A"])
        XCTAssertEqual(sections.first?.threads.map(\.id), ["thread-b"])
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

    func testProjectSectionsPromoteNewlyUpdatedProjectIntoVisibleLimit() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "a-1", updatedAt: 120, status: .idle, cwd: "/tmp/A/one"),
            thread(id: "b-1", updatedAt: 119, status: .idle, cwd: "/tmp/B/one"),
            thread(id: "c-1", updatedAt: 118, status: .idle, cwd: "/tmp/C/one"),
            thread(id: "d-1", updatedAt: 117, status: .idle, cwd: "/tmp/D/one"),
            thread(id: "e-1", updatedAt: 116, status: .idle, cwd: "/tmp/E/one"),
            thread(id: "f-1", updatedAt: 115, status: .idle, cwd: "/tmp/F/one")
        ])

        store.mergeRecentThread(thread(id: "f-1", updatedAt: 200, status: .idle, cwd: "/tmp/F/one"))

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B"),
            .init(path: "/tmp/C", displayName: "C"),
            .init(path: "/tmp/D", displayName: "D"),
            .init(path: "/tmp/E", displayName: "E"),
            .init(path: "/tmp/F", displayName: "F")
        ])

        let sections = store.projectSections(using: catalog, maxProjects: 5, maxThreads: 8)

        XCTAssertEqual(sections.map(\.displayName), ["F", "A", "B", "C", "D"])
        XCTAssertEqual(sections.first?.threads.map(\.id), ["f-1"])
    }

    func testProjectSectionsPromoteRunningProjectIntoVisibleLimit() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "a-1", updatedAt: 120, status: .idle, cwd: "/tmp/A/one"),
            thread(id: "b-1", updatedAt: 119, status: .idle, cwd: "/tmp/B/one"),
            thread(id: "c-1", updatedAt: 118, status: .idle, cwd: "/tmp/C/one"),
            thread(id: "d-1", updatedAt: 117, status: .idle, cwd: "/tmp/D/one"),
            thread(id: "e-1", updatedAt: 116, status: .idle, cwd: "/tmp/E/one"),
            thread(id: "f-idle", updatedAt: 115, status: .idle, cwd: "/tmp/F/idle"),
            thread(id: "f-running", updatedAt: 114, status: .active(flags: []), cwd: "/tmp/F/running")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B"),
            .init(path: "/tmp/C", displayName: "C"),
            .init(path: "/tmp/D", displayName: "D"),
            .init(path: "/tmp/E", displayName: "E"),
            .init(path: "/tmp/F", displayName: "F")
        ])

        let sections = store.projectSections(using: catalog, maxProjects: 5, maxThreads: 5)

        XCTAssertEqual(sections.map(\.displayName), ["A", "B", "C", "D", "F"])
        XCTAssertEqual(sections.last?.threads.map(\.id), ["f-running"])
    }

    func testProjectSectionsPreferWaitingThreadOverNewerRunningThreadAtTightLimit() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 120, status: .active(flags: []), cwd: "/tmp/A/running"),
            thread(id: "waiting", updatedAt: 110, status: .active(flags: [.waitingOnUserInput]), cwd: "/tmp/B/waiting")
        ])

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B")
        ])

        let sections = store.projectSections(using: catalog, maxProjects: 2, maxThreads: 1)

        XCTAssertEqual(sections.map(\.displayName), ["B"])
        XCTAssertEqual(sections.first?.threads.map(\.id), ["waiting"])
    }

    func testProjectCatalogLongestPrefixMatchUsesDeepestRoot() {
        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/Users/tester/workspaces/notion-blog", displayName: "notion-blog"),
            .init(path: "/Users/tester/workspaces/notion-blog/apps/web", displayName: "web")
        ])

        let project = catalog.project(for: "/Users/tester/workspaces/notion-blog/apps/web/pages")

        XCTAssertEqual(project.id, "/Users/tester/workspaces/notion-blog/apps/web")
        XCTAssertEqual(project.displayName, "web")
    }

    func testThreadStatusIconsMatchMenuGlyphs() {
        XCTAssertEqual(AppStateStore.ThreadStatus.waitingForInput.icon, "💬")
        XCTAssertEqual(AppStateStore.ThreadStatus.needsApproval.icon, "💬")
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

    func testDesktopSnapshotDoesNotImmediatelyClearWatchedRunningWhileSessionStateLags() throws {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, path: "/tmp/thread-1.jsonl")
        ])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 150, status: .idle, path: "/tmp/thread-1.jsonl")
        ])

        let lastRuntimeEventAt = try XCTUnwrap(store.recentThreads.first?.lastRuntimeEventAt)

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: lastRuntimeEventAt.addingTimeInterval(4)
        )

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.activeTurnID, "turn-1")
    }

    func testDesktopSnapshotClearsWatchedRunningWhenSessionBackedIdlePersists() throws {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, path: "/tmp/thread-1.jsonl")
        ])

        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 150, status: .idle, path: "/tmp/thread-1.jsonl")
        ])

        let lastRuntimeEventAt = try XCTUnwrap(store.recentThreads.first?.lastRuntimeEventAt)

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: lastRuntimeEventAt.addingTimeInterval(10)
        )

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
        XCTAssertEqual(store.lastDiagnostic, "cleared stale running thread=thread-1 from=Running to=Idle via desktop snapshot")
    }

    func testMergeRecentThreadAddsUnknownThreadWithoutDroppingExistingThreads() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.mergeRecentThread(thread(id: "thread-2", updatedAt: 200, status: .notLoaded))

        XCTAssertEqual(store.recentThreads.map(\.id), ["thread-2", "thread-1"])
        XCTAssertEqual(store.recentThreads.first?.status, .notLoaded)
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
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
        XCTAssertEqual(store.recentThreads.first?.activityUpdatedAt, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testIdleThreadActivityUpdatedAtPrefersTerminalActivity() {
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

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.recentThreads.first?.activityUpdatedAt, Date(timeIntervalSince1970: 300))
    }

    func testIdleThreadActivityUpdatedAtDoesNotKeepStaleRuntimeHeartbeat() {
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
        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.activityUpdatedAt, Date(timeIntervalSince1970: 150))
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

    func testReplaceRecentThreadsKeepsListedApprovalThreadForConfiguredOmissionGrace() throws {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "parent-thread", updatedAt: 150, status: .idle, cwd: "/tmp/project"),
            thread(id: "child-thread", updatedAt: 100, status: .idle, cwd: "/tmp/project", path: "/tmp/child-thread.jsonl")
        ])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                approvalThreadIDs: ["child-thread"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.replaceRecentThreads(
            with: [
                thread(id: "parent-thread", updatedAt: 250, status: .idle, cwd: "/tmp/project")
            ],
            omissionGraceCount: 1
        )

        let child = try XCTUnwrap(store.recentThreads.first(where: { $0.id == "child-thread" }))
        XCTAssertEqual(Set(store.recentThreads.map(\.id)), ["parent-thread", "child-thread"])
        XCTAssertEqual(child.displayStatus, .needsApproval)
        XCTAssertEqual(child.sessionPath, "/tmp/child-thread.jsonl")

        store.replaceRecentThreads(
            with: [
                thread(id: "parent-thread", updatedAt: 260, status: .idle, cwd: "/tmp/project")
            ],
            omissionGraceCount: 1
        )

        XCTAssertEqual(store.recentThreads.map(\.id), ["parent-thread"])
    }

    func testReplaceRecentThreadsPrunesWatchedIdleThreadMissingFromAuthoritativeList() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))

        store.replaceRecentThreads(with: [])

        XCTAssertTrue(store.recentThreads.isEmpty)
    }

    func testReplaceRecentThreadsKeepsListedIdleThreadForConfiguredOmissionGrace() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.replaceRecentThreads(with: [], omissionGraceCount: 1)
        XCTAssertEqual(store.recentThreads.map(\.id), ["thread-1"])
        XCTAssertEqual(store.recentThreads.first?.authoritativeListOmissionCount, 1)

        store.replaceRecentThreads(with: [], omissionGraceCount: 1)
        XCTAssertTrue(store.recentThreads.isEmpty)
    }

    func testReplaceRecentThreadsKeepsStartedIdleThreadMissingFromAuthoritativeList() {
        var store = AppStateStore()
        store.apply(notification: .threadStarted(
            ThreadStartedNotification(
                thread: thread(id: "thread-1", updatedAt: 100, status: .idle)
            )
        ))

        store.replaceRecentThreads(with: [])

        XCTAssertEqual(store.recentThreads.map(\.id), ["thread-1"])
        XCTAssertEqual(store.recentThreads.first?.authoritativeListPresence, .pendingInclusion)
    }

    func testPrunePendingAuthoritativeThreadsRemovesExpiredIdlePendingRows() {
        var store = AppStateStore()
        store.apply(notification: .threadStarted(
            ThreadStartedNotification(
                thread: thread(id: "thread-1", updatedAt: 100, status: .idle)
            )
        ))

        store.prunePendingAuthoritativeThreads(keeping: [])

        XCTAssertTrue(store.recentThreads.isEmpty)
    }

    func testReplaceRecentThreadsKeepsListedRunningThreadForConfiguredOmissionGrace() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [], omissionGraceCount: 1)

        XCTAssertEqual(store.recentThreads.map(\.id), ["thread-1"])
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.authoritativeListOmissionCount, 1)

        store.replaceRecentThreads(with: [], omissionGraceCount: 1)

        XCTAssertTrue(store.recentThreads.isEmpty)
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

    func testDesktopSnapshotClearsUnwatchedFailedWhenFailureDisappears() {
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

        XCTAssertEqual(store.overallStatus, .failed)
        XCTAssertEqual(
            store.recentThreads.first?.displayStatus,
            .failed(message: "Turn error: stream disconnected before completion")
        )

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .notLoaded)
        XCTAssertEqual(store.lastDiagnostic, "cleared stale failed thread=thread-1 from=Failed to=Not loaded via desktop snapshot")
    }

    func testDesktopSnapshotClearsWatchedFailedWhenFailureDisappearsAfterGraceInterval() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))

        store.apply(notification: .threadStatusChanged(
            ThreadStatusChangedNotification(threadId: "thread-1", status: .systemError)
        ))

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .failed(message: nil))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date().addingTimeInterval(10)
        )

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.lastDiagnostic, "cleared stale failed thread=thread-1 from=Failed to=Idle via desktop snapshot")
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

    func testDesktopSnapshotClearsUnwatchedRunningWhenRunningEvidenceDisappears() {
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

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: []
            ),
            observedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.lastDiagnostic, "cleared stale running thread=thread-1 from=Running to=Idle via desktop snapshot")
    }

    func testDesktopOverlayPlaceholderPromotesActualThreadByRuntimeActivity() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "newer-thread", updatedAt: 150, status: .idle)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["older-thread"]
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.mergeRecentThread(thread(id: "older-thread", updatedAt: 100, status: .idle))

        XCTAssertEqual(store.recentThreads.map(\.id), ["older-thread", "newer-thread"])
        XCTAssertEqual(
            store.recentThreads.first(where: { $0.id == "older-thread" })?.updatedAt,
            Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            store.recentThreads.first(where: { $0.id == "older-thread" })?.activityUpdatedAt,
            Date(timeIntervalSince1970: 200)
        )
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

    func testServerRequestResolvedRefreshesActivityUpdatedAtWithoutChangingThreadUpdatedAt() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        usleep(10_000)
        let beforeResolvedAt = Date()

        store.apply(notification: .serverRequestResolved(
            ServerRequestResolvedNotification(threadId: "thread-1")
        ))

        let activityUpdatedAt = store.recentThreads.first?.activityUpdatedAt

        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(activityUpdatedAt)
        XCTAssertGreaterThanOrEqual(activityUpdatedAt ?? .distantPast, beforeResolvedAt)
    }

    func testActiveFlagsMapPendingStates() {
        let cases: [(CodexThreadStatus, AppStateStore.ThreadStatus)] = [
            (.active(flags: [.waitingOnUserInput]), .waitingForInput),
            (.active(flags: [.waitingOnApproval]), .needsApproval),
        ]

        for (listedStatus, expectedStatus) in cases {
            var store = AppStateStore()

            store.replaceRecentThreads(with: [
                thread(id: "thread-1", updatedAt: 100, status: listedStatus)
            ])

            XCTAssertEqual(store.overallStatus, .waitingForUser)
            XCTAssertEqual(store.recentThreads.first?.status, expectedStatus)
        }
    }

    func testDesktopRunningOverlayPreservesExplicitPendingStateWithoutFreshPendingEvidence() {
        let cases: [(AppStateStore.PendingRequestKind, AppStateStore.ThreadStatus)] = [
            (.userInput, .waitingForInput),
            (.approval, .needsApproval),
        ]

        for (pendingRequestKind, expectedStatus) in cases {
            var store = AppStateStore()
            store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
            applyPendingRequest(pendingRequestKind, to: &store)

            store.apply(
                desktopSnapshot: CodexDesktopRuntimeSnapshot(
                    activeTurnCount: 1,
                    runningThreadIDs: ["thread-1"]
                ),
                observedAt: Date(timeIntervalSince1970: 200)
            )

            XCTAssertEqual(store.overallStatus, .waitingForUser)
            XCTAssertEqual(store.recentThreads.first?.status, expectedStatus)
            XCTAssertEqual(store.recentThreads.first?.displayStatus, expectedStatus)
        }
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

    func testSummaryTextSeparatesReplyAndApprovalCounts() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "reply-thread", updatedAt: 100, status: .active(flags: [.waitingOnUserInput])),
            thread(id: "approval-thread", updatedAt: 90, status: .active(flags: [.waitingOnApproval]))
        ])

        XCTAssertEqual(store.summaryText, "Recent 2 | Watching 0 | Running 0 | Reply 1 | Approval 1")
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

    func testConnectedDesktopSnapshotClearsWatchedActiveTurnAfterGraceWithoutRunningEvidence() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.apply(
            connectedDesktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date().addingTimeInterval(6)
        )

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.activeTurnID)
    }

    func testConnectedDesktopSnapshotDoesNotReviveCompletedThreadFromStaleActiveCount() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))
        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        store.apply(
            connectedDesktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.desktopActiveTurnCount, 0)
    }

    func testDesktopCompletionHintClearsRunningState() {
        let completionAt = Date().addingTimeInterval(1)
        let cases: [(inout AppStateStore) -> Void] = [
            { store in
                store.replaceRecentThreads(with: [self.thread(id: "thread-1", updatedAt: 100, status: .idle)])
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
            },
            { store in
                store.replaceRecentThreads(with: [self.thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])
                store.apply(
                    desktopSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 1,
                        runningThreadIDs: ["thread-1"]
                    ),
                    observedAt: Date(timeIntervalSince1970: 200)
                )
            },
        ]

        for configure in cases {
            var store = AppStateStore()
            configure(&store)

            store.apply(desktopCompletionHints: [
                "thread-1": completionAt
            ])

            XCTAssertEqual(store.overallStatus, .idle)
            XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
            XCTAssertNil(store.recentThreads.first?.activeTurnID)
            XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, completionAt)
        }
    }

    func testDesktopCompletionHintClearsRunningRevivedAfterLiveCompletion() throws {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))
        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))
        let completedAt = try XCTUnwrap(store.recentThreads.first?.lastTerminalActivityAt)

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            observedAt: completedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .running)

        store.apply(desktopCompletionHints: ["thread-1": completedAt])

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.desktopActiveTurnCount, 0)
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

    func testMarkWatchedPreservesNewerRuntimeStatusWithoutAdvancingUpdatedAt() {
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
        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
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

    func testThreadListRefreshClearsWatchedPendingStateWhenIncomingAuthoritativeStatusIsNewer() {
        let cases: [(AppStateStore.PendingRequestKind, CodexThreadStatus, AppStateStore.ThreadStatus)] = [
            (.userInput, .idle, .idle),
            (.userInput, .notLoaded, .notLoaded),
            (.approval, .idle, .idle),
        ]

        for (pendingRequestKind, incomingStatus, expectedStatus) in cases {
            var store = AppStateStore()
            let newerUpdatedAt = Int(Date().addingTimeInterval(60).timeIntervalSince1970)
            store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
            applyPendingRequest(pendingRequestKind, to: &store)

            store.replaceRecentThreads(with: [
                thread(id: "thread-1", updatedAt: newerUpdatedAt, status: incomingStatus)
            ])

            XCTAssertEqual(store.recentThreads.first?.status, expectedStatus)
            XCTAssertEqual(store.recentThreads.first?.displayStatus, expectedStatus)
        }
    }

    func testDesktopSnapshotDoesNotOverrideWatchedWaitingWithoutSessionEvidence() {
        let snapshots = [
            CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"]
            ),
            CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
        ]

        for snapshot in snapshots {
            var store = AppStateStore()
            store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
            applyPendingRequest(.userInput, to: &store)

            store.replaceRecentThreads(with: [
                thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
            ])

            store.apply(
                desktopSnapshot: snapshot,
                observedAt: Date(timeIntervalSince1970: 200)
            )

            XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
            XCTAssertEqual(store.recentThreads.first?.listedStatus, .notLoaded)
            XCTAssertEqual(store.recentThreads.first?.displayStatus, .waitingForInput)
            XCTAssertEqual(store.overallStatus, .waitingForUser)
        }
    }

    func testDesktopSnapshotClearsWatchedWaitingWithoutSessionPathAfterGraceWhenPendingDisappears() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .idle))
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: []
            ),
            observedAt: Date().addingTimeInterval(6)
        )

        XCTAssertEqual(store.overallStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertNil(store.recentThreads.first?.pendingRequestKind)
    }

    func testDesktopSnapshotUpdatesSessionBackedWaitingState() {
        let cases: [(CodexDesktopRuntimeSnapshot?, Date?, AppStateStore.OverallStatus, AppStateStore.ThreadStatus, AppStateStore.PendingRequestKind?)] = [
            (nil, nil, .waitingForUser, .waitingForInput, .userInput),
            (
                CodexDesktopRuntimeSnapshot(
                    activeTurnCount: 0,
                    runningThreadIDs: []
                ),
                Date(timeIntervalSince1970: 300),
                .idle,
                .idle,
                nil
            ),
            (
                CodexDesktopRuntimeSnapshot(
                    activeTurnCount: 1,
                    runningThreadIDs: ["thread-1"]
                ),
                Date(timeIntervalSince1970: 300),
                .running,
                .running,
                nil
            ),
        ]

        for (followupSnapshot, followupObservedAt, expectedOverallStatus, expectedDisplayStatus, expectedPendingRequestKind) in cases {
            var store = AppStateStore()
            store.markWatched(thread: thread(
                id: "thread-1",
                updatedAt: 100,
                status: .idle,
                path: "/tmp/thread-1.jsonl"
            ))

            store.apply(
                desktopSnapshot: CodexDesktopRuntimeSnapshot(
                    activeTurnCount: 0,
                    runningThreadIDs: [],
                    waitingForInputThreadIDs: ["thread-1"]
                ),
                observedAt: Date(timeIntervalSince1970: 200)
            )

            if let followupSnapshot, let followupObservedAt {
                store.apply(
                    desktopSnapshot: followupSnapshot,
                    observedAt: followupObservedAt
                )
            }

            XCTAssertEqual(store.overallStatus, expectedOverallStatus)
            XCTAssertEqual(store.recentThreads.first?.displayStatus, expectedDisplayStatus)
            XCTAssertEqual(store.recentThreads.first?.pendingRequestKind, expectedPendingRequestKind)
        }
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

    func testTurnFailureMarksThreadFailed() {
        let cases = [false, true]

        for appliesPendingRequest in cases {
            var store = AppStateStore()
            store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

            if appliesPendingRequest {
                applyPendingRequest(.userInput, to: &store)
            }

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

    func testThreadListRefreshReplacesInferredCompletionTimeWithAuthoritativeUpdatedAt() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 120, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 120))
        XCTAssertFalse(store.recentThreads.first?.hasInferredTerminalActivity ?? true)
    }

    func testMarkWatchedIdleInfersLastTerminalActivityAt() {
        var store = AppStateStore()

        store.markWatched(thread: thread(id: "thread-1", updatedAt: 120, status: .idle))

        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 120))
    }

    func testMarkWatchedDoesNotAdvanceExistingIdleThreadActivityFromResumePayload() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.markWatched(thread: thread(id: "thread-1", updatedAt: 300, status: .idle))

        XCTAssertEqual(store.recentThreads.first?.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.recentThreads.first?.activityUpdatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(store.recentThreads.first?.isWatched ?? false)
    }

    func testClearLiveRuntimeStateFallsBackToAuthoritativeCompletionTime() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 120, status: .idle)])

        store.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        store.clearLiveRuntimeState()

        XCTAssertEqual(store.recentThreads.first?.displayStatus, .idle)
        XCTAssertEqual(store.recentThreads.first?.lastTerminalActivityAt, Date(timeIntervalSince1970: 120))
        XCTAssertEqual(store.recentThreads.first?.activityUpdatedAt, Date(timeIntervalSince1970: 120))
        XCTAssertNil(store.recentThreads.first?.lastRuntimeEventAt)
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

    func testConnectionFailureDoesNotMaskThreadStatus() {
        let cases: [(CodexThreadStatus, AppStateStore.OverallStatus)] = [
            (.active(flags: []), .running),
            (.active(flags: [.waitingOnUserInput]), .waitingForUser),
        ]

        for (threadStatus, expectedOverallStatus) in cases {
            var store = AppStateStore()
            store.setConnection(.failed(message: "Codex app-server exited with status 1"))
            store.replaceRecentThreads(with: [
                thread(id: "thread-1", updatedAt: 100, status: threadStatus)
            ])

            XCTAssertEqual(store.overallStatus, expectedOverallStatus)
        }
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

    func testReplaceRecentThreadsRecordsSubagentParentThreadID() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(
                id: "child-thread",
                updatedAt: 100,
                status: .idle,
                source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#
            )
        ])

        XCTAssertEqual(store.recentThreads.first?.parentThreadID, "parent-thread")
    }

    func testSubagentThreadContributesToOverallStatusWhenParentExists() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "parent-thread", updatedAt: 100, status: .idle),
            thread(
                id: "child-thread",
                updatedAt: 110,
                status: .active(flags: []),
                source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#
            )
        ])

        XCTAssertEqual(store.overallStatus, .running)
    }

    func testArchivedParentRemovalRemovesDescendantsImmediately() {
        let cases: [(inout AppStateStore) -> Void] = [
            { store in
                store.removeThreads(threadIDs: ["parent-thread"])
            },
            { store in
                store.apply(notification: .threadArchived(ThreadArchivedNotification(threadId: "parent-thread")))
            },
        ]

        for removeArchivedParent in cases {
            var store = AppStateStore()
            store.replaceRecentThreads(with: [
                thread(id: "survivor-thread", updatedAt: 120, status: .idle),
                thread(id: "parent-thread", updatedAt: 110, status: .idle),
                thread(
                    id: "child-thread",
                    updatedAt: 100,
                    status: .active(flags: []),
                    source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#
                )
            ])

            removeArchivedParent(&store)

            XCTAssertEqual(store.recentThreads.map(\.id), ["survivor-thread"])
            XCTAssertEqual(store.visibleRecentThreads.map(\.id), ["survivor-thread"])
        }
    }

    func testArchivedThreadTombstoneIgnoresLateRuntimeEventsAndStaleLists() {
        var store = AppStateStore()
        let archivedThread = thread(id: "archived-thread", updatedAt: 110, status: .active(flags: []))
        let survivorThread = thread(id: "survivor-thread", updatedAt: 100, status: .idle)
        store.replaceRecentThreads(with: [archivedThread, survivorThread])

        store.apply(notification: .threadArchived(ThreadArchivedNotification(threadId: "archived-thread")))
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "archived-thread",
                turn: CodexTurn(id: "late-turn", status: .inProgress, error: nil)
            )
        ))
        store.apply(notification: .threadStatusChanged(
            ThreadStatusChangedNotification(threadId: "archived-thread", status: .active(flags: []))
        ))
        store.replaceRecentThreads(with: [archivedThread, survivorThread])

        XCTAssertEqual(store.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertNotNil(store.archivedThreadTombstonesByID["archived-thread"])
    }

    private func thread(
        id: String,
        updatedAt: Int,
        status: CodexThreadStatus,
        cwd: String? = nil,
        path: String? = nil,
        source: String? = nil
    ) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt - 10,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd ?? "/tmp/\(id)",
            name: nil,
            path: path,
            source: source
        )
    }

    private func applyPendingRequest(
        _ pendingRequestKind: AppStateStore.PendingRequestKind,
        to store: inout AppStateStore,
        threadID: String = "thread-1"
    ) {
        switch pendingRequestKind {
        case .userInput:
            store.apply(serverRequest: .toolUserInput(
                ToolRequestUserInputRequest(threadId: threadID, turnId: "turn-1", itemId: "item-1")
            ))
        case .approval:
            store.apply(serverRequest: .approval(
                ApprovalRequestPayload(threadId: threadID, turnId: "turn-1", itemId: "item-1", reason: nil)
            ))
        }
    }
}
