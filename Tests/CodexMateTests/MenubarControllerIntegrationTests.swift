import XCTest
@testable import CodexMate

@MainActor
final class MenubarControllerIntegrationTests: XCTestCase {
    func testRefreshDesktopActivityDiscoversAndSeedsUnknownProject() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([]),
                .success([thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/B/work")])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertTrue(effects.shouldRequestDesktopActivityRefresh)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["thread-b"])
    }

    func testRefreshDesktopActivityDoesNotDiscoverUnknownProjectFromViewOnlyActivity() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestViewed: [
                        "thread-b": Date(timeIntervalSince1970: 200)
                    ]
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/B/work")])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertFalse(effects.shouldRequestThreadRefresh)
        XCTAssertFalse(effects.shouldRequestDesktopActivityRefresh)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
    }

    func testRefreshDesktopActivityDiscoversAndSeedsUnknownApprovalSubagent() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        approvalThreadIDs: ["child-thread"]
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([
                    thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work")
                ]),
                .success([
                    subagentThread(
                        id: "child-thread",
                        updatedAt: 200,
                        cwd: "/tmp/A/work",
                        parentThreadID: "parent-thread",
                        status: .active(flags: [.waitingOnApproval])
                    )
                ])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertTrue(effects.shouldRequestDesktopActivityRefresh)
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["parent-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.map(\.id), ["child-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.first?.thread.displayStatus, .needsApproval)
    }


    func testRefreshThreadsPreservesSeededApprovalSubagentOutsideAuthoritativeRecentList() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        approvalThreadIDs: ["child-thread"]
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work")],
                [thread(id: "parent-thread", updatedAt: 250, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([
                    thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work")
                ]),
                .success([
                    subagentThread(
                        id: "child-thread",
                        updatedAt: 200,
                        cwd: "/tmp/A/work",
                        parentThreadID: "parent-thread",
                        status: .active(flags: [.waitingOnApproval])
                    )
                ]),
                .success([
                    thread(id: "parent-thread", updatedAt: 250, cwd: "/tmp/A/work")
                ])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        _ = await controller.refreshDesktopActivity()
        _ = try await controller.refreshThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["parent-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.map(\.id), ["child-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.first?.thread.displayStatus, .needsApproval)
    }

    func testRefreshDesktopActivityKeepsPendingDiscoveryWhenMetadataIsMissingUntilThreadRefreshResolvesIt() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")],
                [
                    thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/B/work"),
                    thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")
                ]
            ],
            metadataResponses: [
                .success([]),
                .success([])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let desktopEffects = await controller.refreshDesktopActivity()
        let beforeRefreshSnapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(desktopEffects.shouldRequestThreadRefresh)
        XCTAssertFalse(desktopEffects.shouldRequestDesktopActivityRefresh)
        XCTAssertEqual(beforeRefreshSnapshot.projectSections.map(\.section.displayName), ["A"])

        _ = try await controller.refreshThreads()
        let afterRefreshSnapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(afterRefreshSnapshot.projectSections.map(\.section.displayName), ["B", "A"])
    }

    func testSnapshotPromotesRuntimeActiveProjectOrder() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 1,
                        runningThreadIDs: ["thread-b"],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                )
            ],
            recentThreadResponses: [
                [
                    thread(id: "thread-a", updatedAt: 150, cwd: "/tmp/A/work"),
                    thread(id: "thread-b", updatedAt: 100, cwd: "/tmp/B/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        _ = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .running)
    }

    func testRefreshDesktopActivityShowsRunningStatusAndRequestsBackfillForUntrackedActiveTurn() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 1,
                        runningThreadIDs: []
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertEqual(snapshot.overallStatus, .running)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
    }

    func testCompletionHintsClearWaitingStateInSnapshot() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestCompleted: [
                        "thread-a": Date(timeIntervalSince1970: 200)
                    ]
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        controller.apply(serverRequest: .toolUserInput(
            ToolRequestUserInputRequest(threadId: "thread-a", turnId: "turn-1", itemId: "item-1")
        ))

        var snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .waitingForInput)

        _ = await controller.refreshDesktopActivity()
        snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
    }

    func testCompletionHintsMarkIdleThreadUnreadEvenWithoutObservedRunningState() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestCompleted: [
                        "thread-a": Date(timeIntervalSince1970: 200)
                    ]
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        _ = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(snapshot.projectSections.first?.threads.first?.hasUnreadContent ?? false)
        XCTAssertEqual(snapshot.overallStatus, .idle)
    }

    func testRefreshThreadsFallsBackToFolderNameWhenProjectCatalogLoadFails() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/scratch-area")]
            ],
            projectCatalog: .failure(TestError(message: "catalog unavailable"))
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["scratch-area"])
    }

    func testDiscoveredThreadKeepsUnreadMarkersConsistentAcrossCompletionAndRead() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                )
            ],
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([]),
                .success([thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/B/work")])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        _ = await controller.refreshDesktopActivity()

        controller.apply(notification: .turnCompleted(
            TurnCompletedNotification(
                threadId: "thread-b",
                turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
            )
        ))

        var snapshot = controller.prepareSnapshot().snapshot
        XCTAssertTrue(snapshot.projectSections.flatMap(\.threads).first(where: { $0.id == "thread-b" })?.hasUnreadContent ?? false)

        XCTAssertTrue(controller.markThreadRead("thread-b"))

        snapshot = controller.prepareSnapshot().snapshot
        XCTAssertFalse(snapshot.projectSections.flatMap(\.threads).first(where: { $0.id == "thread-b" })?.hasUnreadContent ?? true)
    }

    func testLoadInitialThreadsKeepsOrphanSubagentVisibleInSnapshot() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                    thread(id: "subagent-thread", updatedAt: 200, cwd: "/tmp/A/work")
                ]
            ],
            metadataResponses: [
                .success([
                    thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                    subagentThread(id: "subagent-thread", updatedAt: 200, cwd: "/tmp/A/work")
                ])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["subagent-thread", "main-thread"])
        XCTAssertEqual(controller.visibleRecentThreads.map(\.id), ["main-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["subagent-thread", "main-thread"])
        XCTAssertTrue(snapshot.projectSections.first?.threadGroups.isEmpty ?? false)
        XCTAssertTrue(snapshot.isWatchLatestThreadEnabled)
    }

    func testLoadInitialThreadsGroupsSubagentThreadUnderParentInSnapshot() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                    thread(id: "child-thread", updatedAt: 200, cwd: "/tmp/A/work")
                ]
            ],
            metadataResponses: [
                .success([
                    thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                    subagentThread(
                        id: "child-thread",
                        updatedAt: 200,
                        cwd: "/tmp/A/work",
                        parentThreadID: "parent-thread"
                    )
                ])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["parent-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.count, 1)
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.id, "parent-thread")
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.map(\.id), ["child-thread"])
    }

    func testSnapshotOverallStatusIgnoresWaitingSubagentWhenMainThreadIsIdle() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        controller.apply(notification: .threadStarted(
            ThreadStartedNotification(
                thread: subagentThread(
                    id: "child-thread",
                    updatedAt: 200,
                    cwd: "/tmp/A/work",
                    parentThreadID: "parent-thread",
                    status: .active(flags: [.waitingOnUserInput])
                )
            )
        ))
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
        XCTAssertEqual(
            snapshot.projectSections.first?.threadGroups.first?.childThreads.first?.thread.displayStatus,
            .waitingForInput
        )
    }

    func testThreadStartedNotificationKeepsOrphanSubagentVisibleInSnapshot() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        controller.apply(notification: .threadStarted(
            ThreadStartedNotification(thread: subagentThread(id: "subagent-thread", updatedAt: 200, cwd: "/tmp/A/work"))
        ))

        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["subagent-thread", "main-thread"])
        XCTAssertEqual(controller.visibleRecentThreads.map(\.id), ["main-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["subagent-thread", "main-thread"])
        XCTAssertTrue(snapshot.projectSections.first?.threadGroups.isEmpty ?? false)
    }

    func testRemoveThreadsImmediatelyDropsArchivedProjectFromSnapshot() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work", status: .active(flags: [])),
                    thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()

        var snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(snapshot.overallStatus, .running)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])

        controller.removeThreads(threadIDs: ["archived-thread"])
        snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["survivor-thread"])
    }

    func testThreadArchivedNotificationImmediatelyDropsArchivedProjectFromSnapshot() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work", status: .active(flags: [])),
                    thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()

        controller.apply(notification: .threadArchived(ThreadArchivedNotification(threadId: "archived-thread")))
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["survivor-thread"])
    }

    func testRefreshThreadsPrunesWatchedArchivedThreadWhenAuthoritativeListOmitsIt() async throws {
        let archivedThread = thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work")
        let survivorThread = thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
        let controller = makeController(
            recentThreadResponses: [
                [archivedThread, survivorThread],
                [survivorThread]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        controller.markWatched(thread: archivedThread)

        _ = try await controller.refreshThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
    }

    func testPruneThreadsMissingFromDesktopStateRemovesThreadKeptOnlyByStaleRecentList() async throws {
        let archivedListed = thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work")
        let survivorListed = thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
        let archivedMetadata = thread(
            id: "archived-thread",
            updatedAt: 200,
            cwd: "/tmp/B/work",
            path: "/tmp/B/archived.jsonl",
            source: "",
            agentRole: "",
            agentNickname: ""
        )
        let survivorMetadata = thread(
            id: "survivor-thread",
            updatedAt: 100,
            cwd: "/tmp/A/work",
            path: "/tmp/A/survivor.jsonl",
            source: "",
            agentRole: "",
            agentNickname: ""
        )

        let controller = makeController(
            recentThreadResponses: [
                [archivedListed, survivorListed]
            ],
            metadataResponses: [
                .success([archivedMetadata, survivorMetadata]),
                .success([survivorMetadata])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let effects = await controller.pruneThreadsMissingFromDesktopState()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map { $0.id }, ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map { $0.section.displayName }, ["A"])
        XCTAssertEqual(effects.diagnostics.count, 1)
    }

    func testPrepareSnapshotAppliesVisibleThreadLimitOverridePerProject() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work"),
                    thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/A/work"),
                    thread(id: "thread-c", updatedAt: 300, cwd: "/tmp/A/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot(visibleThreadLimit: 2).snapshot

        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["thread-c", "thread-b"])
    }

    func testPrepareSnapshotPrioritizesWaitingSubagentGroupOverNewerIdleThreadsAtTightLimit() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "idle-newest", updatedAt: 400, cwd: "/tmp/A/work"),
                    thread(id: "idle-middle", updatedAt: 300, cwd: "/tmp/A/work"),
                    thread(id: "parent-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                    subagentThread(
                        id: "child-thread",
                        updatedAt: 110,
                        cwd: "/tmp/A/work",
                        parentThreadID: "parent-thread",
                        status: .active(flags: [.waitingOnApproval])
                    )
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot(visibleThreadLimit: 2).snapshot

        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["parent-thread", "idle-newest"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.id, "parent-thread")
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.map(\.id), ["child-thread"])
    }

    func testPrepareSnapshotPrioritizesProjectsWithAttentionWhenProjectLimitIsTight() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "idle-c", updatedAt: 300, cwd: "/tmp/C/work"),
                    thread(id: "idle-b", updatedAt: 200, cwd: "/tmp/B/work"),
                    thread(id: "parent-a", updatedAt: 100, cwd: "/tmp/A/work"),
                    subagentThread(
                        id: "child-a",
                        updatedAt: 110,
                        cwd: "/tmp/A/work",
                        parentThreadID: "parent-a",
                        status: .active(flags: [.waitingOnApproval])
                    )
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B"),
                    .init(path: "/tmp/C", displayName: "C")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot(projectLimit: 2, visibleThreadLimit: 1).snapshot

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A", "C"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["parent-a"])
        XCTAssertEqual(snapshot.projectSections.first?.threadGroups.first?.childThreads.map(\.id), ["child-a"])
    }

    func testPrepareSnapshotAppliesProjectLimitOverride() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work"),
                    thread(id: "thread-b", updatedAt: 200, cwd: "/tmp/B/work"),
                    thread(id: "thread-c", updatedAt: 300, cwd: "/tmp/C/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B"),
                    .init(path: "/tmp/C", displayName: "C")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot(projectLimit: 2).snapshot

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["C", "B"])
    }

    func testPrepareSnapshotAppliesProjectAndThreadLimitOverridesIndependently() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [
                    thread(id: "thread-a-1", updatedAt: 100, cwd: "/tmp/A/work"),
                    thread(id: "thread-a-2", updatedAt: 400, cwd: "/tmp/A/work"),
                    thread(id: "thread-b-1", updatedAt: 300, cwd: "/tmp/B/work"),
                    thread(id: "thread-c-1", updatedAt: 200, cwd: "/tmp/C/work")
                ]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B"),
                    .init(path: "/tmp/C", displayName: "C")
                ])
            )
        )

        try await controller.loadInitialThreads()
        let snapshot = controller.prepareSnapshot(projectLimit: 2, visibleThreadLimit: 1).snapshot

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A", "B"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["thread-a-2"])
        XCTAssertEqual(snapshot.projectSections.dropFirst().first?.threads.map(\.id), ["thread-b-1"])
    }

    func testLoadInitialThreadsExpandsBootstrapWindowUntilConfiguredProjectCountIsAvailable() async throws {
        let recentThreadListing = RecordingRecentThreadListing(threads: [
            thread(id: "thread-a-1", updatedAt: 500, cwd: "/tmp/A/work"),
            thread(id: "thread-a-2", updatedAt: 490, cwd: "/tmp/A/work"),
            thread(id: "thread-a-3", updatedAt: 480, cwd: "/tmp/A/work"),
            thread(id: "thread-a-4", updatedAt: 470, cwd: "/tmp/A/work"),
            thread(id: "thread-b-1", updatedAt: 460, cwd: "/tmp/B/work"),
            thread(id: "thread-b-2", updatedAt: 450, cwd: "/tmp/B/work"),
            thread(id: "thread-c-1", updatedAt: 440, cwd: "/tmp/C/work"),
            thread(id: "thread-c-2", updatedAt: 430, cwd: "/tmp/C/work"),
            thread(id: "thread-d-1", updatedAt: 420, cwd: "/tmp/D/work"),
            thread(id: "thread-d-2", updatedAt: 410, cwd: "/tmp/D/work"),
            thread(id: "thread-e-1", updatedAt: 400, cwd: "/tmp/E/work")
        ])
        let threadMetadataReader = RecordingThreadMetadataReader()
        let controller = MenubarController(
            desktopActivityLoader: FakeDesktopActivityLoader(updates: []),
            recentThreadListing: recentThreadListing,
            threadMetadataReader: threadMetadataReader,
            projectCatalogLoader: FakeProjectCatalogLoader(
                result: .success(
                    CodexDesktopProjectCatalog(workspaceRoots: [
                        .init(path: "/tmp/A", displayName: "A"),
                        .init(path: "/tmp/B", displayName: "B"),
                        .init(path: "/tmp/C", displayName: "C"),
                        .init(path: "/tmp/D", displayName: "D"),
                        .init(path: "/tmp/E", displayName: "E")
                    ])
                )
            ),
            configuration: MenubarControllerConfiguration(
                initialFetchLimit: 2,
                maxTrackedThreads: 12,
                projectLimit: 5,
                visibleThreadLimit: 2,
                maxPendingDiscoveredThreads: 64,
                pendingDiscoveredThreadTTL: 120,
                threadReadMarkerRetentionSeconds: 30 * 24 * 60 * 60
            )
        )

        try await controller.loadInitialThreads()
        let initialSnapshot = controller.prepareSnapshot().snapshot
        let initialRequestedLimits = await recentThreadListing.requestedLimits()
        let metadataRequests = await threadMetadataReader.requestedThreadIDs()

        XCTAssertEqual(initialRequestedLimits, [10, 12])
        XCTAssertEqual(metadataRequests.count, 1)
        XCTAssertEqual(metadataRequests.first?.count, 11)
        XCTAssertEqual(initialSnapshot.projectSections.map(\.section.displayName), ["A", "B", "C", "D", "E"])

        _ = try await controller.refreshThreads()
        let refreshedSnapshot = controller.prepareSnapshot().snapshot
        let refreshedRequestedLimits = await recentThreadListing.requestedLimits()

        XCTAssertEqual(refreshedRequestedLimits, [10, 12, 12])
        XCTAssertEqual(refreshedSnapshot.projectSections.map(\.section.displayName), ["A", "B", "C", "D", "E"])
    }

    private func makeController(
        desktopUpdates: [DesktopActivityUpdate] = [],
        recentThreadResponses: [[CodexThread]],
        metadataResponses: [Result<[CodexThread], Error>] = [],
        projectCatalog: Result<CodexDesktopProjectCatalog, Error> = .success(.empty)
    ) -> MenubarController {
        MenubarController(
            desktopActivityLoader: FakeDesktopActivityLoader(updates: desktopUpdates),
            recentThreadListing: FakeRecentThreadListing(responses: recentThreadResponses),
            threadMetadataReader: FakeThreadMetadataReader(results: metadataResponses),
            projectCatalogLoader: FakeProjectCatalogLoader(result: projectCatalog),
            configuration: MenubarControllerConfiguration(
                initialFetchLimit: 32,
                maxTrackedThreads: 256,
                projectLimit: 5,
                visibleThreadLimit: 8,
                maxPendingDiscoveredThreads: 64,
                pendingDiscoveredThreadTTL: 120,
                threadReadMarkerRetentionSeconds: 30 * 24 * 60 * 60
            )
        )
    }

    private func desktopUpdate(
        runtimeSnapshot: CodexDesktopRuntimeSnapshot? = CodexDesktopRuntimeSnapshot(
            activeTurnCount: 0,
            runningThreadIDs: []
        ),
        latestViewed: [String: Date] = [:],
        latestCompleted: [String: Date] = [:],
        runtimeError: String? = nil
    ) -> DesktopActivityUpdate {
        DesktopActivityUpdate(
            runtimeSnapshot: runtimeSnapshot,
            latestViewedAtByThreadID: latestViewed,
            latestTurnCompletedAtByThreadID: latestCompleted,
            runtimeErrorMessage: runtimeError
        )
    }

    private func thread(
        id: String,
        updatedAt: Int,
        cwd: String,
        status: CodexThreadStatus = .idle,
        path: String? = nil,
        source: String? = nil,
        agentRole: String? = nil,
        agentNickname: String? = nil
    ) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt - 10,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd,
            name: nil,
            path: path,
            source: source,
            agentRole: agentRole,
            agentNickname: agentNickname
        )
    }

    private func subagentThread(
        id: String,
        updatedAt: Int,
        cwd: String,
        parentThreadID: String = "parent-thread",
        status: CodexThreadStatus = .idle
    ) -> CodexThread {
        thread(
            id: id,
            updatedAt: updatedAt,
            cwd: cwd,
            status: status,
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parentThreadID)","depth":1,"agent_nickname":"Harvey","agent_role":"explorer"}}}"#,
            agentRole: "explorer",
            agentNickname: "Harvey"
        )
    }
}

private actor FakeDesktopActivityLoader: DesktopActivityLoading {
    private var updates: [DesktopActivityUpdate]

    init(updates: [DesktopActivityUpdate]) {
        self.updates = updates
    }

    func load(candidateSessionPaths: [String: String?], now: Date) async -> DesktopActivityUpdate {
        guard !updates.isEmpty else {
            return DesktopActivityUpdate(
                runtimeSnapshot: CodexDesktopRuntimeSnapshot(activeTurnCount: 0, runningThreadIDs: []),
                latestViewedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:],
                runtimeErrorMessage: nil
            )
        }

        return updates.removeFirst()
    }
}

private actor FakeRecentThreadListing: RecentThreadListing {
    private var responses: [[CodexThread]]

    init(responses: [[CodexThread]]) {
        self.responses = responses
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        guard !responses.isEmpty else {
            return []
        }

        return responses.removeFirst()
    }
}

private actor RecordingRecentThreadListing: RecentThreadListing {
    private let threads: [CodexThread]
    private var requested: [Int] = []

    init(threads: [CodexThread]) {
        self.threads = threads
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        requested.append(limit)
        return Array(threads.prefix(limit))
    }

    func requestedLimits() -> [Int] {
        requested
    }
}

private actor RecordingThreadMetadataReader: ThreadMetadataReading {
    private var requested: [Set<String>] = []

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        requested.append(threadIDs)
        return []
    }

    func requestedThreadIDs() -> [Set<String>] {
        requested
    }
}

private final class FakeThreadMetadataReader: ThreadMetadataReading, @unchecked Sendable {
    private var results: [Result<[CodexThread], Error>]

    init(results: [Result<[CodexThread], Error>]) {
        self.results = results
    }

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        guard !results.isEmpty else {
            return []
        }

        return try results.removeFirst().get()
    }
}

private final class FakeProjectCatalogLoader: ProjectCatalogLoading, @unchecked Sendable {
    private let result: Result<CodexDesktopProjectCatalog, Error>

    init(result: Result<CodexDesktopProjectCatalog, Error>) {
        self.result = result
    }

    func loadProjectCatalog() async throws -> CodexDesktopProjectCatalog {
        try result.get()
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
