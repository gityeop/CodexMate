import XCTest
@testable import CodextensionMenubar

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

    func testSnapshotKeepsLatestProjectOrderWhileReflectingRunningStatus() async throws {
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

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A", "B"])
        XCTAssertEqual(snapshot.projectSections.last?.threads.first?.thread.displayStatus, .running)
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
        status: CodexThreadStatus = .idle
    ) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt - 10,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd,
            name: nil
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

private final class FakeThreadMetadataReader: ThreadMetadataReading {
    private var results: [Result<[CodexThread], Error>]

    init(results: [Result<[CodexThread], Error>]) {
        self.results = results
    }

    func threads(threadIDs: Set<String>) throws -> [CodexThread] {
        guard !results.isEmpty else {
            return []
        }

        return try results.removeFirst().get()
    }
}

private final class FakeProjectCatalogLoader: ProjectCatalogLoading {
    private let result: Result<CodexDesktopProjectCatalog, Error>

    init(result: Result<CodexDesktopProjectCatalog, Error>) {
        self.result = result
    }

    func loadProjectCatalog() throws -> CodexDesktopProjectCatalog {
        try result.get()
    }
}

private struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
