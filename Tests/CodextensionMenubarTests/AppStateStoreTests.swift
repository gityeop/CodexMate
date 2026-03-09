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
    }

    func testDesktopRunningOverlayUpdatesUnwatchedThread() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertFalse(store.recentThreads.first?.isWatched ?? true)
    }

    func testDesktopRunningOverlayClearsWhenSnapshotNoLongerContainsThread() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                hasInProgressActivity: false,
                lastAppServerEvent: "app-server event: item/completed"
            ),
            observedAt: Date(timeIntervalSince1970: 201)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.summaryText, "Recent 1 | Watching 0 | Running 0 | Waiting 0 | Approval 0")
    }

    func testUserInputRequestMarksWaitingForInput() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testDesktopRunningOverlayDoesNotDowngradeWaitingForInput() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
    }

    func testThreadListRefreshPreservesWatchedWaitingForInputWhenServerReturnsIdle() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-1", turnId: "turn-1", itemId: "item-1")
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .waitingForInput)
        XCTAssertEqual(store.overallStatus, .waitingForInput)
    }

    func testThreadListRefreshPreservesWatchedApprovalWhenServerReturnsIdle() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])
        store.apply(serverRequest: .approval(
            ApprovalRequestPayload(threadId: "thread-1", turnId: "turn-1", itemId: "item-1", reason: nil)
        ))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .idle)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .needsApproval)
        XCTAssertEqual(store.overallStatus, .needsApproval)
    }

    func testDesktopActiveTurnCountKeepsOverallRunningWithoutThreadOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .notLoaded)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: [],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/started"
            )
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.summaryText, "Recent 1 | Watching 0 | Running 1 | Waiting 0 | Approval 0")
    }

    func testThreadListRefreshKeepsWatchedRuntimeStatusWhenDesktopStillReportsRunning() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))
        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["thread-1"],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 120)
        )

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .running)
        XCTAssertTrue(store.recentThreads.first?.isWatched ?? false)
    }

    func testThreadListRefreshClearsWatchedRunningStatusWithoutDesktopConfirmation() {
        var store = AppStateStore()
        store.markWatched(thread: thread(id: "thread-1", updatedAt: 100, status: .active(flags: [])))

        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 110, status: .notLoaded)
        ])

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
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
    }

    func testThreadStatusMapsWaitingFlagsSeparately() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "waiting", updatedAt: 200, status: .active(flags: [.waitingOnUserInput])),
            thread(id: "approval", updatedAt: 100, status: .active(flags: [.waitingOnApproval])),
            thread(id: "running", updatedAt: 50, status: .active(flags: [])),
        ])

        XCTAssertEqual(store.recentThreads.first(where: { $0.id == "waiting" })?.status, .waitingForInput)
        XCTAssertEqual(store.recentThreads.first(where: { $0.id == "approval" })?.status, .needsApproval)
        XCTAssertEqual(store.recentThreads.first(where: { $0.id == "running" })?.status, .running)
    }

    func testOverallStatusPrefersWaitingForInputOverRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 200, status: .active(flags: [])),
            thread(id: "waiting", updatedAt: 100, status: .active(flags: [.waitingOnUserInput])),
        ])

        XCTAssertEqual(store.overallStatus, .waitingForInput)
    }

    func testOverallStatusPrefersApprovalOverRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 200, status: .active(flags: [])),
            thread(id: "approval", updatedAt: 100, status: .active(flags: [.waitingOnApproval])),
        ])

        XCTAssertEqual(store.overallStatus, .needsApproval)
    }

    func testProjectSectionsUseLongestMatchingWorkspaceRootAndSavedLabel() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: [
                    "/Users/test/workspace",
                    "/Users/test/workspace/app",
                ],
                labelsByRoot: [
                    "/Users/test/workspace": "Workspace Root",
                    "/Users/test/workspace/app": "Sidebar App",
                ]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "nested", updatedAt: 200, status: .idle, cwd: "/Users/test/workspace/app/Sources"),
            thread(id: "root", updatedAt: 100, status: .idle, cwd: "/Users/test/workspace/docs"),
        ])

        XCTAssertEqual(store.projectSections.map(\.displayName), ["Sidebar App", "Workspace Root"])
        XCTAssertEqual(store.projectSections.first?.threads.map(\.id), ["nested"])
    }

    func testProjectSectionsFallBackToFolderNameWhenLabelMissing() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Users/test/MyProject"],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 100, status: .idle, cwd: "/Users/test/MyProject/Sources")
        ])

        XCTAssertEqual(store.projectSections.first?.displayName, "MyProject")
    }

    func testProjectSectionsSortProjectsAndThreadsNewestFirstAndApplyCaps() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: [
                    "/Projects/A",
                    "/Projects/B",
                    "/Projects/C",
                    "/Projects/D",
                    "/Projects/E",
                    "/Projects/F",
                    "/Projects/G",
                ],
                labelsByRoot: [:]
            )
        )

        let threads = [
            thread(id: "a6", updatedAt: 706, status: .idle, cwd: "/Projects/A"),
            thread(id: "a5", updatedAt: 705, status: .idle, cwd: "/Projects/A"),
            thread(id: "a4", updatedAt: 704, status: .idle, cwd: "/Projects/A"),
            thread(id: "a3", updatedAt: 703, status: .idle, cwd: "/Projects/A"),
            thread(id: "a2", updatedAt: 702, status: .idle, cwd: "/Projects/A"),
            thread(id: "a1", updatedAt: 701, status: .idle, cwd: "/Projects/A"),
            thread(id: "b", updatedAt: 650, status: .idle, cwd: "/Projects/B"),
            thread(id: "c", updatedAt: 640, status: .idle, cwd: "/Projects/C"),
            thread(id: "d", updatedAt: 630, status: .idle, cwd: "/Projects/D"),
            thread(id: "e", updatedAt: 620, status: .idle, cwd: "/Projects/E"),
            thread(id: "f", updatedAt: 610, status: .idle, cwd: "/Projects/F"),
            thread(id: "g", updatedAt: 600, status: .idle, cwd: "/Projects/G"),
        ]
        store.replaceRecentThreads(with: threads)

        XCTAssertEqual(store.projectSections.map(\.displayName), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(store.projectSections.first?.threads.map(\.id), ["a6", "a5", "a4", "a3", "a2"])
        XCTAssertEqual(store.projectSections.first?.totalThreadCount, 6)
    }

    func testProjectSectionsDoNotMergeDifferentRootsWithSameVisibleFolderName() {
        var store = AppStateStore()
        store.setProjectCatalog(.empty)
        store.replaceRecentThreads(with: [
            thread(id: "thread-1", updatedAt: 200, status: .idle, cwd: "/tmp/foo/app"),
            thread(id: "thread-2", updatedAt: 100, status: .idle, cwd: "/Users/test/bar/app"),
        ])

        XCTAssertEqual(store.projectSections.count, 2)
        XCTAssertEqual(store.projectSections.map(\.displayName), ["app", "app"])
        XCTAssertNotEqual(store.projectSections[0].id, store.projectSections[1].id)
    }

    func testProjectBadgesPrioritizeWaitingThenApprovalThenRunning() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: [
                    "/Projects/Waiting",
                    "/Projects/Approval",
                    "/Projects/Running",
                    "/Projects/Idle",
                ],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "waiting", updatedAt: 100, status: .active(flags: [.waitingOnUserInput]), cwd: "/Projects/Waiting"),
            thread(id: "approval", updatedAt: 110, status: .active(flags: [.waitingOnApproval]), cwd: "/Projects/Approval"),
            thread(id: "running", updatedAt: 120, status: .active(flags: []), cwd: "/Projects/Running"),
            thread(id: "idle", updatedAt: 130, status: .idle, cwd: "/Projects/Idle"),
        ])

        XCTAssertEqual(store.projectBadges.map(\.displayName), ["Waiting", "Approval", "Running", "Idle"])
        XCTAssertEqual(store.projectBadges.map(\.threadID), ["waiting", "approval", "running", "idle"])
    }

    func testProjectBadgeUsesHighestPriorityThreadWithinProject() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Projects/App"],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "idle", updatedAt: 200, status: .idle, cwd: "/Projects/App"),
            thread(id: "waiting", updatedAt: 100, status: .active(flags: [.waitingOnUserInput]), cwd: "/Projects/App"),
        ])

        XCTAssertEqual(store.projectBadges.first?.threadID, "waiting")
        XCTAssertEqual(store.projectBadges.first?.status, .waitingForInput)
    }

    func testProjectBadgesUseCompactTitlesAndIncludeIdleProjects() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Projects/VeryLongProjectName"],
                labelsByRoot: ["/Projects/VeryLongProjectName": "VeryLongProjectName"]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "idle", updatedAt: 100, status: .idle, cwd: "/Projects/VeryLongProjectName")
        ])

        XCTAssertEqual(store.projectBadges.first?.title, "✅ Very…")
    }

    func testProjectBadgesFallBackToSavedProjectsWhenNoRecentThreadsExist() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: [
                    "/Projects/A",
                    "/Projects/B",
                    "/Projects/C",
                ],
                activeRoots: ["/Projects/B"],
                labelsByRoot: [:]
            )
        )

        XCTAssertEqual(store.projectBadges.map(\.displayName), ["B", "A", "C"])
        XCTAssertEqual(store.projectBadges.map(\.threadID), [nil, nil, nil])
    }

    func testActionableThreadCountIncludesWaitingAndApprovalOnly() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "waiting", updatedAt: 300, status: .active(flags: [.waitingOnUserInput])),
            thread(id: "approval", updatedAt: 200, status: .active(flags: [.waitingOnApproval])),
            thread(id: "running", updatedAt: 100, status: .active(flags: [])),
            thread(id: "idle", updatedAt: 50, status: .idle),
        ])

        XCTAssertEqual(store.actionableThreadCount, 2)
    }

    func testStatusIconAnimationModeUsesIdleRowWhenNoActionableThreadsExist() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 200, status: .active(flags: [])),
            thread(id: "idle", updatedAt: 100, status: .idle),
        ])

        XCTAssertEqual(store.statusIconAnimationMode, .idle)
    }

    func testStatusIconAnimationModeUsesAlertRowWhenActionableThreadsExist() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [
            thread(id: "waiting", updatedAt: 200, status: .active(flags: [.waitingOnUserInput])),
            thread(id: "idle", updatedAt: 100, status: .idle),
        ])

        XCTAssertEqual(store.statusIconAnimationMode, .alert)
    }

    func testPanelProjectsPreferActionableProjectsOverMoreRecentIdleProjects() {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Projects/Action", "/Projects/Recent"],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "recent-idle", updatedAt: 300, status: .idle, cwd: "/Projects/Recent"),
            thread(id: "actionable", updatedAt: 200, status: .active(flags: [.waitingOnApproval]), cwd: "/Projects/Action"),
        ])

        XCTAssertEqual(store.panelProjects.map(\.displayName), ["Action", "Recent"])
    }

    func testPanelProjectsUseDominantStatusPriorityAndSummaryCounts() throws {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Projects/App"],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "running", updatedAt: 300, status: .active(flags: []), cwd: "/Projects/App"),
            thread(id: "failure", updatedAt: 250, status: .systemError, cwd: "/Projects/App"),
            thread(id: "approval", updatedAt: 200, status: .active(flags: [.waitingOnApproval]), cwd: "/Projects/App"),
            thread(id: "waiting", updatedAt: 150, status: .active(flags: [.waitingOnUserInput]), cwd: "/Projects/App"),
        ])

        let project = try XCTUnwrap(store.panelProjects.first)
        XCTAssertEqual(project.dominantStatus, .waitingForInput)
        XCTAssertEqual(project.waitingForInputCount, 1)
        XCTAssertEqual(project.approvalCount, 1)
        XCTAssertEqual(project.runningCount, 1)
        XCTAssertEqual(project.failedCount, 1)
    }

    func testPanelProjectsCapVisibleThreadsAndExposeHiddenCount() throws {
        var store = AppStateStore()
        store.setProjectCatalog(
            CodexDesktopProjectCatalog(
                savedRoots: ["/Projects/App"],
                labelsByRoot: [:]
            )
        )
        store.replaceRecentThreads(with: [
            thread(id: "t6", updatedAt: 600, status: .idle, cwd: "/Projects/App"),
            thread(id: "t5", updatedAt: 500, status: .idle, cwd: "/Projects/App"),
            thread(id: "t4", updatedAt: 400, status: .idle, cwd: "/Projects/App"),
            thread(id: "t3", updatedAt: 300, status: .idle, cwd: "/Projects/App"),
            thread(id: "t2", updatedAt: 200, status: .idle, cwd: "/Projects/App"),
            thread(id: "t1", updatedAt: 100, status: .idle, cwd: "/Projects/App"),
        ])

        let project = try XCTUnwrap(store.panelProjects.first)
        XCTAssertEqual(project.threads.map(\.id), ["t6", "t5", "t4", "t3", "t2"])
        XCTAssertEqual(project.hiddenThreadCount, 1)
    }

    func testInProgressActivityKeepsOverallStatusRunning() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
    }

    func testInProgressActivityDoesNotMarkIdleThreadRunningWithoutThreadOverlay() {
        var store = AppStateStore()
        store.replaceRecentThreads(with: [thread(id: "thread-1", updatedAt: 100, status: .idle)])

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                hasInProgressActivity: true,
                lastAppServerEvent: "app-server event: item/agentMessage/delta"
            ),
            observedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(store.overallStatus, .running)
        XCTAssertEqual(store.recentThreads.first?.status, .idle)
    }

    func testWatchedRunningThreadClearsAfterIdleDesktopObservation() {
        var store = AppStateStore()
        store.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-1",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        store.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 0,
                runningThreadIDs: [],
                hasInProgressActivity: false,
                lastAppServerEvent: "app-server event: item/completed"
            ),
            observedAt: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(store.recentThreads.first?.status, .idle)
        XCTAssertEqual(store.overallStatus, .idle)
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
