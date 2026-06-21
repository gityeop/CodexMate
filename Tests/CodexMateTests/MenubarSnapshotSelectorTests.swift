import XCTest
@testable import CodexMate

final class MenubarSnapshotSelectorTests: XCTestCase {
    func testSnapshotKeepsConfiguredThreadLimitInsteadOfTopThreeRecentThreads() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-1", updatedAt: 400),
                codexThread(id: "thread-2", updatedAt: 300),
                codexThread(id: "thread-3", updatedAt: 200),
                codexThread(id: "thread-4", updatedAt: 100)
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 1,
            visibleThreadLimit: 4
        )

        XCTAssertEqual(
            snapshot.menuSections.first?.threads.map(\.thread.id),
            ["thread-1", "thread-2", "thread-3", "thread-4"]
        )
    }

    func testSnapshotProvidesMenuSectionsWithoutRebuildingFromControllerState() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work"),
                codexThread(id: "thread-b", updatedAt: 300, cwd: "/tmp/B/work"),
                codexThread(id: "thread-c", updatedAt: 200, cwd: "/tmp/C/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 2,
            visibleThreadLimit: 1
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["B", "C"])
        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["B", "C"])
        XCTAssertEqual(snapshot.menuSections.map(\.threadCount), [1, 1])
    }

    func testSnapshotUsesThreadWorkspaceRootHintForProjectGrouping() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "local-thread", updatedAt: 100, cwd: "/tmp/A/work"),
                codexThread(id: "worktree-thread", updatedAt: 300, cwd: "/tmp/.codex/worktrees/3a2e/codextension")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ],
                threadWorkspaceRootHints: [
                    "worktree-thread": "/tmp/A"
                ]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 1,
            visibleThreadLimit: 2
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(
            snapshot.menuSections.first?.threads.map(\.thread.id),
            ["worktree-thread", "local-thread"]
        )
    }

    func testSnapshotKeepsListedThreadWithoutProjectCatalogRoot() throws {
        var state = AppStateStore()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMateUnmatchedProject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directoryURL)
        }

        state.replaceRecentThreads(
            with: [
                codexThread(id: "unmatched-thread", updatedAt: 100, cwd: directoryURL.path),
                codexThread(id: "survivor-thread", updatedAt: 90, cwd: "/tmp/A/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), [directoryURL.lastPathComponent, "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["unmatched-thread"])
        XCTAssertTrue(snapshot.hasRecentThreads)
        XCTAssertTrue(snapshot.isWatchLatestThreadEnabled)
    }

    func testSnapshotKeepsRecentUnmatchedThreadWhileProjectCatalogCatchesUp() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "new-thread", updatedAt: 950, cwd: "/tmp/New Project"),
                codexThread(id: "survivor-thread", updatedAt: 900, cwd: "/tmp/A/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["New Project", "A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["new-thread"])
    }

    func testSnapshotKeepsPendingUnmatchedThreadWhileProjectCatalogCatchesUp() {
        var state = AppStateStore()
        state.apply(
            notification: .threadStarted(
                ThreadStartedNotification(
                    thread: codexThread(id: "pending-thread", updatedAt: 100, cwd: "/tmp/New Project")
                )
            )
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["New Project"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["pending-thread"])
    }

    func testSnapshotHidesUnhydratedRunningPlaceholderUntilMetadataArrives() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "known-thread", updatedAt: 100, cwd: "/tmp/A/work")
            ]
        )
        state.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: ["unhydrated-thread"]
            )
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3
        )

        XCTAssertEqual(state.overallStatus, .running)
        XCTAssertTrue(state.recentThreads.contains { $0.id == "unhydrated-thread" })
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertFalse(snapshot.projectSections.flatMap(\.allThreads).contains { $0.id == "unhydrated-thread" })
    }

    func testSnapshotHidesUnhydratedCompletedPlaceholderUntilMetadataArrives() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "known-thread", updatedAt: 100, cwd: "/tmp/A/work")
            ]
        )
        state.apply(
            notification: .turnCompleted(
                TurnCompletedNotification(
                    threadId: "unhydrated-thread",
                    turn: CodexTurn(id: "turn-1", status: .completed, error: nil)
                )
            )
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(lastReadTerminalAtByThreadID: [
                "unhydrated-thread": 0
            ]),
            projectLimit: 3,
            visibleThreadLimit: 3
        )

        XCTAssertTrue(state.recentThreads.contains { $0.id == "unhydrated-thread" })
        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertFalse(snapshot.projectSections.flatMap(\.allThreads).contains { $0.id == "unhydrated-thread" })
        XCTAssertFalse(snapshot.hasUnreadThreads)
    }

    func testSnapshotBucketsSubagentWithProjectlessParentInsteadOfScratchProject() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "parent-thread", updatedAt: 200, cwd: "/tmp/Scratch Parent"),
                codexThread(
                    id: "child-thread",
                    updatedAt: 210,
                    status: .active(flags: []),
                    cwd: "/tmp/Pet Installer Scratch",
                    source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","depth":1}}}"#
                )
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ],
                projectlessThreadIDs: ["parent-thread"]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["Chats"])
        XCTAssertEqual(snapshot.projectSections.first?.allThreads.map(\.id).sorted(), ["child-thread", "parent-thread"])
        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["Chats"])
    }

    func testSnapshotReportsNoVisibleRecentThreadsWhenOnlyRemovedProjectThreadsRemain() {
        var state = AppStateStore()
        let removedProjectPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMateRemovedProject-\(UUID().uuidString)", isDirectory: true)
            .path
        state.replaceRecentThreads(
            with: [
                codexThread(id: "removed-thread", updatedAt: 100, cwd: removedProjectPath)
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: CodexDesktopProjectCatalog(
                workspaceRoots: [
                    .init(path: "/tmp/A", displayName: "A")
                ]
            ),
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 3,
            visibleThreadLimit: 3,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertTrue(snapshot.projectSections.isEmpty)
        XCTAssertFalse(snapshot.hasRecentThreads)
        XCTAssertFalse(snapshot.isWatchLatestThreadEnabled)
    }

    func testSnapshotDoesNotShowRunningForUnattributedActiveTurn() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-1", updatedAt: 100)
            ]
        )
        state.apply(
            desktopSnapshot: CodexDesktopRuntimeSnapshot(
                activeTurnCount: 1,
                runningThreadIDs: []
            )
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            projectLimit: 1,
            visibleThreadLimit: 1
        )

        XCTAssertEqual(state.overallStatus, .running)
        XCTAssertEqual(snapshot.overallStatus, .idle)
        XCTAssertEqual(snapshot.projectSections.first?.threads.first?.thread.displayStatus, .idle)
    }

    func testSnapshotAddsPinnedSectionAndRemovesPinnedThreadFromRecentMode() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work"),
                codexThread(id: "thread-b", updatedAt: 300, cwd: "/tmp/B/work"),
                codexThread(id: "thread-c", updatedAt: 200, cwd: "/tmp/C/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            threadListViewMode: .recent,
            pinnedThreadIDs: ["thread-b"],
            projectLimit: 1,
            visibleThreadLimit: 2
        )

        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["Pinned", "Recent"])
        XCTAssertEqual(snapshot.menuSections.first?.threads.map(\.thread.id), ["thread-b"])
        XCTAssertEqual(snapshot.menuSections.dropFirst().first?.threads.map(\.thread.id), ["thread-c", "thread-a"])
    }

    func testSnapshotDoesNotBackfillProjectSectionWhenPinnedThreadsConsumeVisibleRoots() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-a-1", updatedAt: 500, cwd: "/tmp/A/work"),
                codexThread(id: "thread-a-2", updatedAt: 400, cwd: "/tmp/A/work"),
                codexThread(id: "thread-a-3", updatedAt: 300, cwd: "/tmp/A/work"),
                codexThread(id: "thread-a-4", updatedAt: 200, cwd: "/tmp/A/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            pinnedThreadIDs: ["thread-a-1", "thread-a-2"],
            projectLimit: 1,
            visibleThreadLimit: 2
        )

        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["Pinned"])
        XCTAssertEqual(snapshot.menuSections.first?.threads.map(\.thread.id), ["thread-a-1", "thread-a-2"])
    }

    func testSnapshotHidesMissingPinnedThreadButKeepsNormalMenuSections() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "thread-a", updatedAt: 100, cwd: "/tmp/A/work")
            ]
        )

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(),
            pinnedThreadIDs: ["missing-thread"],
            projectLimit: 3,
            visibleThreadLimit: 3
        )

        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["A"])
        XCTAssertEqual(snapshot.menuSections.first?.threads.map(\.thread.id), ["thread-a"])
    }

    func testSnapshotBuildsStatusSectionsWithWaitRunningUnreadAndOtherPriority() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(
                    id: "wait-thread",
                    updatedAt: 400,
                    status: .active(flags: [.waitingOnUserInput]),
                    cwd: "/tmp/A/work"
                ),
                codexThread(
                    id: "running-thread",
                    updatedAt: 300,
                    status: .active(flags: []),
                    cwd: "/tmp/B/work"
                ),
                codexThread(id: "unread-thread", updatedAt: 200, cwd: "/tmp/C/work"),
                codexThread(id: "other-thread", updatedAt: 100, cwd: "/tmp/A/work")
            ]
        )
        state.markWatched(thread: codexThread(id: "unread-thread", updatedAt: 200, cwd: "/tmp/C/work"))

        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: ThreadReadMarkerStore(lastReadTerminalAtByThreadID: [
                "unread-thread": 0
            ]),
            threadListViewMode: .status,
            projectLimit: 3,
            visibleThreadLimit: 5
        )

        XCTAssertEqual(snapshot.menuSections.map(\.displayName), ["Wait", "Running", "Unread", "Other"])
        XCTAssertEqual(snapshot.menuSections[0].threads.map(\.thread.id), ["wait-thread"])
        XCTAssertEqual(snapshot.menuSections[1].threads.map(\.thread.id), ["running-thread"])
        XCTAssertEqual(snapshot.menuSections[2].threads.map(\.thread.id), ["unread-thread"])
        XCTAssertEqual(snapshot.menuSections[3].threads.map(\.thread.id), ["other-thread"])
    }

    private let projectCatalog = CodexDesktopProjectCatalog(
        workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A"),
            .init(path: "/tmp/B", displayName: "B"),
            .init(path: "/tmp/C", displayName: "C")
        ]
    )

    private func codexThread(
        id: String,
        updatedAt: Int,
        status: CodexThreadStatus = .idle,
        cwd: String = "/tmp/A/work",
        source: String? = nil
    ) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd,
            name: "Thread \(id)",
            source: source
        )
    }
}
