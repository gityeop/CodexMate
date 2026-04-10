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
