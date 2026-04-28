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

    func testRefreshDesktopActivityReloadsProjectCatalogForThreadWorkspaceRootHints() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    )
                )
            ],
            recentThreadResponses: [
                [
                    thread(id: "worktree-thread", updatedAt: 200, cwd: "/tmp/.codex/worktrees/faa7/guldin"),
                    thread(id: "root-thread", updatedAt: 100, cwd: "/tmp/guldin/root")
                ]
            ],
            projectCatalogResponses: [
                .success(
                    CodexDesktopProjectCatalog(workspaceRoots: [
                        .init(path: "/tmp/guldin", displayName: "guldin")
                    ])
                ),
                .success(
                    CodexDesktopProjectCatalog(
                        workspaceRoots: [
                            .init(path: "/tmp/guldin", displayName: "guldin")
                        ],
                        threadWorkspaceRootHints: [
                            "worktree-thread": "/tmp/guldin"
                        ]
                    )
                )
            ]
        )

        try await controller.loadInitialThreads()
        let initialSnapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(initialSnapshot.projectSections.count, 1)
        XCTAssertEqual(initialSnapshot.projectSections.map(\.section.displayName), ["guldin"])
        XCTAssertEqual(initialSnapshot.projectSections.first?.threads.map(\.id), ["root-thread"])

        _ = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(snapshot.projectSections.count, 1)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["guldin"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["worktree-thread", "root-thread"])
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
        XCTAssertTrue(effects.shouldRequestDesktopActivityAfterThreadRefresh)
        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
    }

    func testConnectedRefreshDesktopActivityPromotesRunningStatusFromDesktopHint() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 1,
                        runningThreadIDs: ["thread-a"],
                        recentActivityThreadIDs: ["thread-a"]
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
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))

        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertEqual(snapshot.overallStatus, .running)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .running)
    }

    func testConnectedRefreshDesktopActivityIgnoresStaleCompletionHintForLiveRunningThread() async throws {
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
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))
        controller.apply(notification: .turnStarted(
            TurnStartedNotification(
                threadId: "thread-a",
                turn: CodexTurn(id: "turn-1", status: .inProgress, error: nil)
            )
        ))

        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertFalse(effects.shouldRequestThreadRefresh)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .running)
    }

    func testConnectedRefreshDesktopActivityAppliesCompletionHintForMissedTurnCompletion() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestCompleted: [
                        "thread-a": Date().addingTimeInterval(60)
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
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))

        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot
        let threadSnapshot = snapshot.projectSections.first?.threads.first

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertEqual(threadSnapshot?.thread.displayStatus, .idle)
        XCTAssertTrue(threadSnapshot?.hasUnreadContent ?? false)
        XCTAssertTrue(snapshot.hasUnreadThreads)
    }

    func testConnectedRefreshDesktopActivityStillSeedsDiscoveredThreadFromBackfill() async throws {
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
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))

        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.shouldRequestThreadRefresh)
        XCTAssertTrue(effects.shouldRequestDesktopActivityRefresh)
        XCTAssertTrue(effects.shouldBoostThreadDiscovery)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
    }

    func testRefreshDesktopActivityRetriesPendingDiscoveryMetadataUntilThreadAppears() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                ),
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["thread-b"]
                    )
                )
            ],
            recentThreadResponses: [
                [
                    thread(
                        id: "thread-a",
                        updatedAt: 100,
                        cwd: "/tmp/A/work",
                        path: "/tmp/thread-a.jsonl",
                        source: "manual",
                        agentRole: "assistant",
                        agentNickname: "A"
                    )
                ],
                [
                    thread(
                        id: "thread-a",
                        updatedAt: 110,
                        cwd: "/tmp/A/work",
                        path: "/tmp/thread-a.jsonl",
                        source: "manual",
                        agentRole: "assistant",
                        agentNickname: "A"
                    )
                ]
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

        let firstDesktopEffects = await controller.refreshDesktopActivity()
        XCTAssertTrue(firstDesktopEffects.shouldRequestThreadRefresh)
        XCTAssertTrue(firstDesktopEffects.shouldBoostThreadDiscovery)
        XCTAssertEqual(controller.prepareSnapshot().snapshot.projectSections.map(\.section.displayName), ["A"])

        let refreshEffects = try await controller.refreshThreads()
        XCTAssertTrue(refreshEffects.shouldBoostThreadDiscovery)
        XCTAssertEqual(controller.prepareSnapshot().snapshot.projectSections.map(\.section.displayName), ["A"])

        let secondDesktopEffects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(secondDesktopEffects.shouldBoostThreadDiscovery)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["thread-b"])
    }

    func testCompletionHintsClearWaitingStateInSnapshot() async throws {
        let completionAt = Date().addingTimeInterval(60)
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestCompleted: [
                        "thread-a": completionAt
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

    func testWarmResumeDoesNotMarkExistingIdleThreadUnread() async throws {
        let controller = makeController(
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
        var snapshot = controller.prepareSnapshot().snapshot
        XCTAssertFalse(snapshot.projectSections.first?.threads.first?.hasUnreadContent ?? true)

        XCTAssertTrue(controller.markWatched(thread: thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")))
        snapshot = controller.prepareSnapshot().snapshot

        XCTAssertFalse(snapshot.projectSections.first?.threads.first?.hasUnreadContent ?? true)
        XCTAssertEqual(controller.persistedThreadReadMarkers["thread-a"], 100)
    }

    func testWarmResumeRepairsLegacyZeroMarkerForExistingIdleThread() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            initialThreadReadMarkers: ["thread-a": 0],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ])
            )
        )

        try await controller.loadInitialThreads()
        XCTAssertTrue(controller.markWatched(thread: thread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")))

        let snapshot = controller.prepareSnapshot().snapshot
        XCTAssertFalse(snapshot.projectSections.first?.threads.first?.hasUnreadContent ?? true)
        XCTAssertEqual(controller.persistedThreadReadMarkers["thread-a"], 100)
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

    func testRefreshThreadsKeepsStartedTopLevelThreadUntilAuthoritativeListCatchesUp() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")],
                [thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            )
        )

        try await controller.loadInitialThreads()
        controller.apply(notification: .threadStarted(
            ThreadStartedNotification(
                thread: thread(id: "new-thread", updatedAt: 200, cwd: "/tmp/B/work")
            )
        ))

        _ = try await controller.refreshThreads()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["new-thread", "main-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["new-thread"])
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

    func testRefreshDesktopActivityImmediatelyDropsTrackedThreadFromDesktopArchiveHint() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    latestArchiveRequested: [
                        "archived-thread": Date(timeIntervalSince1970: 250)
                    ]
                )
            ],
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
        let effects = await controller.refreshDesktopActivity()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertTrue(effects.diagnostics.contains(where: { $0.contains("desktop hinted archive threads=[archived") }))
        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["survivor-thread"])
    }

    func testRefreshDesktopActivityIgnoresStaleDesktopArchiveHintOlderThanTrackedThread() async throws {
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    latestArchiveRequested: [
                        "survivor-thread": Date(timeIntervalSince1970: 150)
                    ]
                )
            ],
            recentThreadResponses: [
                [
                    thread(id: "survivor-thread", updatedAt: 200, cwd: "/tmp/A/work", status: .active(flags: []))
                ]
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

        XCTAssertFalse(effects.diagnostics.contains(where: { $0.contains("desktop hinted archive") }))
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .running)
    }

    func testRefreshThreadsKeepsWatchedArchivedThreadThroughFirstAuthoritativeOmission() async throws {
        let archivedThread = thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work")
        let survivorThread = thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
        let controller = makeController(
            recentThreadResponses: [
                [archivedThread, survivorThread],
                [survivorThread],
                [survivorThread],
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
        var snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["archived-thread", "survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])

        _ = try await controller.refreshThreads()
        snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["archived-thread", "survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])

        _ = try await controller.refreshThreads()
        snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(controller.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
    }

    func testRefreshThreadsPrunesRunningThreadAfterAuthoritativeOmissionGrace() async throws {
        let archivedThread = thread(id: "archived-thread", updatedAt: 200, cwd: "/tmp/B/work", status: .active(flags: []))
        let survivorThread = thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
        let controller = makeController(
            recentThreadResponses: [
                [archivedThread, survivorThread],
                [survivorThread],
                [survivorThread],
                [survivorThread]
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { Date(timeIntervalSince1970: 250) }
        )

        try await controller.loadInitialThreads()
        _ = try await controller.refreshThreads()
        var snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["archived-thread", "survivor-thread"])
        XCTAssertEqual(snapshot.overallStatus, .running)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])

        _ = try await controller.refreshThreads()
        snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(controller.recentThreads.map(\.id), ["archived-thread", "survivor-thread"])
        XCTAssertEqual(snapshot.overallStatus, .running)
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])

        _ = try await controller.refreshThreads()
        snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(controller.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.overallStatus, .idle)
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

    func testPruneThreadsMissingFromDesktopStateImmediatelyRemovesArchivedListedThread() async throws {
        let archivedListed = thread(id: "archived-thread", updatedAt: 495, cwd: "/tmp/B/work")
        let survivorListed = thread(id: "survivor-thread", updatedAt: 490, cwd: "/tmp/A/work")
        let archivedMetadata = thread(
            id: "archived-thread",
            updatedAt: 495,
            cwd: "/tmp/B/work",
            path: "/tmp/B/archived.jsonl",
            source: "",
            agentRole: "",
            agentNickname: ""
        )
        let survivorMetadata = thread(
            id: "survivor-thread",
            updatedAt: 490,
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
            archivedMetadataResponses: [
                .success(["archived-thread"])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { Date(timeIntervalSince1970: 500) }
        )

        try await controller.loadInitialThreads()
        let effects = await controller.pruneThreadsMissingFromDesktopState()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(effects.diagnostics.count, 1)
    }

    func testPruneThreadsMissingFromDesktopStateRemovesStaleThreadWhileConnected() async throws {
        let missingFromDesktopState = thread(id: "missing-thread", updatedAt: 200, cwd: "/tmp/B/work")
        let survivorThread = thread(id: "survivor-thread", updatedAt: 100, cwd: "/tmp/A/work")
        let controller = makeController(
            recentThreadResponses: [
                [missingFromDesktopState, survivorThread]
            ],
            metadataResponses: [
                .success([survivorThread]),
                .success([survivorThread])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { Date(timeIntervalSince1970: 500) }
        )

        try await controller.loadInitialThreads()
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))

        let effects = await controller.pruneThreadsMissingFromDesktopState()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["survivor-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(effects.diagnostics.count, 1)
    }

    func testPruneThreadsMissingFromDesktopStateKeepsStartedThreadWhileConnected() async throws {
        let controller = makeController(
            recentThreadResponses: [
                [thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")]
            ],
            metadataResponses: [
                .success([thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")]),
                .success([thread(id: "main-thread", updatedAt: 100, cwd: "/tmp/A/work")])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A"),
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { Date(timeIntervalSince1970: 300) }
        )

        try await controller.loadInitialThreads()
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))
        controller.apply(notification: .threadStarted(
            ThreadStartedNotification(
                thread: thread(id: "new-thread", updatedAt: 250, cwd: "/tmp/B/work")
            )
        ))

        let effects = await controller.pruneThreadsMissingFromDesktopState()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["new-thread", "main-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "A"])
        XCTAssertTrue(effects.diagnostics.isEmpty)
    }

    func testPruneThreadsMissingFromDesktopStateKeepsCompletedPendingThreadWhileDiscoveryIsStillPending() async throws {
        let newThread = thread(id: "new-thread", updatedAt: 250, cwd: "/tmp/B/work", status: .active(flags: []))
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: []
                    ),
                    latestCompleted: [
                        "new-thread": Date(timeIntervalSince1970: 260)
                    ]
                )
            ],
            recentThreadResponses: [
                []
            ],
            metadataResponses: [
                .success([])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { Date(timeIntervalSince1970: 500) }
        )

        try await controller.loadInitialThreads()
        controller.setConnection(.connected(binaryPath: "/tmp/codex"))
        controller.apply(notification: .threadStarted(
            ThreadStartedNotification(thread: newThread)
        ))
        _ = await controller.refreshDesktopActivity()

        let effects = await controller.pruneThreadsMissingFromDesktopState()
        let snapshot = controller.prepareSnapshot().snapshot

        XCTAssertEqual(controller.recentThreads.map(\.id), ["new-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
        XCTAssertTrue(effects.diagnostics.isEmpty)
    }

    func testRefreshDesktopActivityKeepsRediscoveredPendingThreadWhenPendingTTLExpires() async throws {
        var currentTime = Date(timeIntervalSince1970: 100)
        let controller = makeController(
            desktopUpdates: [
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["new-thread"]
                    )
                ),
                desktopUpdate(
                    runtimeSnapshot: CodexDesktopRuntimeSnapshot(
                        activeTurnCount: 0,
                        runningThreadIDs: [],
                        recentActivityThreadIDs: ["new-thread"]
                    )
                )
            ],
            recentThreadResponses: [
                []
            ],
            metadataResponses: [
                .success([
                    thread(id: "new-thread", updatedAt: 250, cwd: "/tmp/B/work")
                ])
            ],
            projectCatalog: .success(
                CodexDesktopProjectCatalog(workspaceRoots: [
                    .init(path: "/tmp/B", displayName: "B")
                ])
            ),
            now: { currentTime }
        )

        try await controller.loadInitialThreads()
        _ = await controller.refreshDesktopActivity()
        XCTAssertEqual(controller.recentThreads.map(\.id), ["new-thread"])

        currentTime = Date(timeIntervalSince1970: 221)
        _ = await controller.refreshDesktopActivity()

        let snapshot = controller.prepareSnapshot().snapshot
        XCTAssertEqual(controller.recentThreads.map(\.id), ["new-thread"])
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B"])
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
                results: [
                    .success(
                        CodexDesktopProjectCatalog(workspaceRoots: [
                            .init(path: "/tmp/A", displayName: "A"),
                            .init(path: "/tmp/B", displayName: "B"),
                            .init(path: "/tmp/C", displayName: "C"),
                            .init(path: "/tmp/D", displayName: "D"),
                            .init(path: "/tmp/E", displayName: "E")
                        ])
                    )
                ]
            ),
            configuration: MenubarControllerConfiguration(
                initialFetchLimit: 2,
                maxTrackedThreads: 12,
                projectLimit: 5,
                visibleThreadLimit: 2,
                authoritativeListOmissionGraceCount: 2,
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
        archivedMetadataResponses: [Result<Set<String>, Error>] = [],
        initialThreadReadMarkers: [String: TimeInterval] = [:],
        projectCatalog: Result<CodexDesktopProjectCatalog, Error> = .success(.empty),
        projectCatalogResponses: [Result<CodexDesktopProjectCatalog, Error>] = [],
        now: @escaping () -> Date = Date.init
    ) -> MenubarController {
        MenubarController(
            desktopActivityLoader: FakeDesktopActivityLoader(updates: desktopUpdates),
            recentThreadListing: FakeRecentThreadListing(responses: recentThreadResponses),
            threadMetadataReader: FakeThreadMetadataReader(
                results: metadataResponses,
                archivedResults: archivedMetadataResponses
            ),
            projectCatalogLoader: FakeProjectCatalogLoader(
                results: projectCatalogResponses.isEmpty ? [projectCatalog] : projectCatalogResponses
            ),
            initialThreadReadMarkers: initialThreadReadMarkers,
            configuration: MenubarControllerConfiguration(
                initialFetchLimit: 32,
                maxTrackedThreads: 256,
                projectLimit: 5,
                visibleThreadLimit: 8,
                authoritativeListOmissionGraceCount: 2,
                maxPendingDiscoveredThreads: 64,
                pendingDiscoveredThreadTTL: 120,
                threadReadMarkerRetentionSeconds: 30 * 24 * 60 * 60
            ),
            now: now
        )
    }

    private func desktopUpdate(
        runtimeSnapshot: CodexDesktopRuntimeSnapshot? = CodexDesktopRuntimeSnapshot(
            activeTurnCount: 0,
            runningThreadIDs: []
        ),
        latestViewed: [String: Date] = [:],
        latestStarted: [String: Date] = [:],
        latestCompleted: [String: Date] = [:],
        latestArchiveRequested: [String: Date] = [:],
        latestUnarchiveRequested: [String: Date] = [:],
        runtimeError: String? = nil
    ) -> DesktopActivityUpdate {
        DesktopActivityUpdate(
            runtimeSnapshot: runtimeSnapshot,
            latestViewedAtByThreadID: latestViewed,
            latestTurnStartedAtByThreadID: latestStarted,
            latestTurnCompletedAtByThreadID: latestCompleted,
            latestArchiveRequestedAtByThreadID: latestArchiveRequested,
            latestUnarchiveRequestedAtByThreadID: latestUnarchiveRequested,
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

    func load(candidateSessionContexts: [String: ThreadSessionContext], now: Date) async -> DesktopActivityUpdate {
        guard !updates.isEmpty else {
            return DesktopActivityUpdate(
                runtimeSnapshot: CodexDesktopRuntimeSnapshot(activeTurnCount: 0, runningThreadIDs: []),
                latestViewedAtByThreadID: [:],
                latestTurnStartedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:],
                latestArchiveRequestedAtByThreadID: [:],
                latestUnarchiveRequestedAtByThreadID: [:],
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
    private var archivedResults: [Result<Set<String>, Error>]

    init(
        results: [Result<[CodexThread], Error>],
        archivedResults: [Result<Set<String>, Error>] = []
    ) {
        self.results = results
        self.archivedResults = archivedResults
    }

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        guard !results.isEmpty else {
            return []
        }

        return try results.removeFirst().get()
    }

    func archivedThreadIDs(threadIDs: Set<String>) async throws -> Set<String> {
        guard !archivedResults.isEmpty else {
            return []
        }

        return try archivedResults.removeFirst().get()
    }
}

private final class FakeProjectCatalogLoader: ProjectCatalogLoading, @unchecked Sendable {
    private var results: [Result<CodexDesktopProjectCatalog, Error>]

    init(results: [Result<CodexDesktopProjectCatalog, Error>]) {
        self.results = results
    }

    func loadProjectCatalog() async throws -> CodexDesktopProjectCatalog {
        guard !results.isEmpty else {
            return .empty
        }

        if results.count == 1 {
            return try results[0].get()
        }

        return try results.removeFirst().get()
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
