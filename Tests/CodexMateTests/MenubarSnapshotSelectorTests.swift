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

    func testSnapshotHidesStaleListedThreadForRemovedProjectRoot() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "removed-thread", updatedAt: 100, cwd: "/tmp/Removed Project"),
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

        XCTAssertEqual(snapshot.projectSections.map(\.section.displayName), ["A"])
        XCTAssertEqual(snapshot.projectSections.first?.threads.map(\.id), ["survivor-thread"])
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

    func testSnapshotReportsNoVisibleRecentThreadsWhenOnlyRemovedProjectThreadsRemain() {
        var state = AppStateStore()
        state.replaceRecentThreads(
            with: [
                codexThread(id: "removed-thread", updatedAt: 100, cwd: "/tmp/Removed Project")
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
        cwd: String = "/tmp/A/work"
    ) -> CodexThread {
        CodexThread(
            id: id,
            preview: "Preview \(id)",
            createdAt: updatedAt,
            updatedAt: updatedAt,
            status: .idle,
            cwd: cwd,
            name: "Thread \(id)"
        )
    }
}
