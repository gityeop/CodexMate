import XCTest
@testable import CodexMate

final class ThreadMenuBuilderTests: XCTestCase {
    func testBuildHidesNonAttentionSubagentsByDefaultAndKeepsParentOnly() {
        let parent = threadRow(id: "parent-thread", title: "Main task", updatedAt: 100)
        let runningChild = threadRow(
            id: "running-child",
            title: "Investigate logs",
            updatedAt: 120,
            status: .running,
            isSubagent: true,
            parentThreadID: "parent-thread",
            agentNickname: "Mendel"
        )
        let idleChild = threadRow(
            id: "idle-child",
            title: "Check cache",
            updatedAt: 110,
            status: .idle,
            isSubagent: true,
            parentThreadID: "parent-thread",
            agentNickname: "Turing"
        )

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [snapshotSection(root: parent, childThreads: [runningChild, idleChild])],
            recentThreads: [idleChild, runningChild, parent],
            projectCatalog: projectCatalog
        )

        XCTAssertEqual(sections.first?.threads.map(\.thread.id), ["parent-thread"])
        XCTAssertTrue(sections.first?.threads.first?.children.isEmpty ?? false)
        XCTAssertEqual(sections.first?.threadCount, 1)
    }

    func testBuildShowsAttentionDescendantPathByDefault() {
        let parent = threadRow(id: "parent-thread", title: "Main task", updatedAt: 100)
        let runningChild = threadRow(
            id: "running-child",
            title: "Investigate logs",
            updatedAt: 120,
            status: .running,
            isSubagent: true,
            parentThreadID: "parent-thread",
            agentNickname: "Turing"
        )
        let approvalGrandchild = threadRow(
            id: "approval-grandchild",
            title: "Check signing",
            updatedAt: 130,
            status: .needsApproval,
            isSubagent: true,
            parentThreadID: "running-child",
            agentNickname: "Ramanujan"
        )

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [snapshotSection(root: parent, childThreads: [runningChild])],
            recentThreads: [approvalGrandchild, runningChild, parent],
            projectCatalog: projectCatalog
        )

        XCTAssertEqual(sections.first?.threads.first?.children.map(\.thread.id), ["running-child"])
        XCTAssertEqual(
            sections.first?.threads.first?.children.first?.children.map(\.thread.id),
            ["approval-grandchild"]
        )
    }

    func testBuildKeepsOrphanSubagentVisibleAsSeparateRoot() {
        let parent = threadRow(id: "parent-thread", title: "Main task", updatedAt: 100)
        let orphan = threadRow(
            id: "orphan-child",
            title: "Inspect stale process",
            updatedAt: 200,
            status: .needsApproval,
            isSubagent: true,
            parentThreadID: "missing-parent",
            agentNickname: "Cicero"
        )

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [snapshotSection(root: parent)],
            recentThreads: [orphan, parent],
            projectCatalog: projectCatalog
        )

        XCTAssertEqual(sections.first?.threads.map(\.thread.id), ["orphan-child", "parent-thread"])
    }

    func testBuildDoesNotPromoteSubagentOfHiddenRootAsSeparateRootByDefault() {
        let visibleRoot = threadRow(id: "visible-root", title: "Visible task", updatedAt: 300)
        let hiddenRoot = threadRow(id: "hidden-root", title: "Hidden task", updatedAt: 200)
        let hiddenChild = threadRow(
            id: "hidden-child",
            title: "Hidden subagent",
            updatedAt: 250,
            status: .idle,
            isSubagent: true,
            parentThreadID: "hidden-root",
            agentNickname: "Turing"
        )

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [snapshotSection(root: visibleRoot)],
            recentThreads: [visibleRoot, hiddenChild, hiddenRoot],
            projectCatalog: projectCatalog
        )

        XCTAssertEqual(sections.first?.threads.map(\.thread.id), ["visible-root"])
    }

    func testFallbackBuildAppliesConfiguredProjectAndThreadLimits() {
        let projectCatalog = CodexDesktopProjectCatalog(
            workspaceRoots: [
                .init(path: "/tmp/A", displayName: "A"),
                .init(path: "/tmp/B", displayName: "B"),
                .init(path: "/tmp/C", displayName: "C")
            ]
        )
        let threadA1 = threadRow(id: "thread-a-1", title: "Thread A1", updatedAt: 100, cwd: "/tmp/A/work")
        let threadA2 = threadRow(id: "thread-a-2", title: "Thread A2", updatedAt: 90, cwd: "/tmp/A/work")
        let threadB1 = threadRow(id: "thread-b-1", title: "Thread B1", updatedAt: 300, cwd: "/tmp/B/work")
        let threadC1 = threadRow(id: "thread-c-1", title: "Thread C1", updatedAt: 200, cwd: "/tmp/C/work")

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [],
            recentThreads: [threadA1, threadA2, threadB1, threadC1],
            projectCatalog: projectCatalog,
            projectLimit: 2,
            visibleThreadLimit: 1
        )

        XCTAssertEqual(sections.map(\.displayName), ["B", "C"])
        XCTAssertEqual(sections.map(\.threadCount), [1, 1])
        XCTAssertEqual(sections.first?.threads.map(\.thread.id), ["thread-b-1"])
        XCTAssertEqual(sections.dropFirst().first?.threads.map(\.thread.id), ["thread-c-1"])
    }

    func testBuildPromotesOlderWaitingThreadToTopOfProject() {
        let newerIdleRoot = threadRow(id: "idle-root", title: "Newest idle", updatedAt: 300)
        let olderWaitingRoot = threadRow(
            id: "waiting-root",
            title: "Old waiting",
            updatedAt: 100,
            status: .waitingForInput
        )
        let snapshot = MenubarProjectSectionSnapshot(
            section: AppStateStore.ProjectSection(
                id: "/tmp/A",
                displayName: "A",
                latestUpdatedAt: newerIdleRoot.activityUpdatedAt,
                threads: [newerIdleRoot, olderWaitingRoot]
            ),
            threads: [
                MenubarThreadSnapshot(thread: newerIdleRoot, hasUnreadContent: false),
                MenubarThreadSnapshot(thread: olderWaitingRoot, hasUnreadContent: false)
            ],
            threadGroups: []
        )

        let sections = ThreadMenuBuilder.build(
            snapshotSections: [snapshot],
            recentThreads: [newerIdleRoot, olderWaitingRoot],
            projectCatalog: projectCatalog
        )

        XCTAssertEqual(sections.first?.threads.map(\.thread.id), ["waiting-root", "idle-root"])
    }

    private let projectCatalog = CodexDesktopProjectCatalog(
        workspaceRoots: [
            .init(path: "/tmp/A", displayName: "A")
        ]
    )

    private func snapshotSection(
        root: AppStateStore.ThreadRow,
        childThreads: [AppStateStore.ThreadRow] = []
    ) -> MenubarProjectSectionSnapshot {
        let rootSnapshot = MenubarThreadSnapshot(thread: root, hasUnreadContent: false)
        let childSnapshots = childThreads.map { MenubarThreadSnapshot(thread: $0, hasUnreadContent: false) }
        let threadGroups = childSnapshots.isEmpty
            ? []
            : [MenubarThreadGroupSnapshot(thread: rootSnapshot, childThreads: childSnapshots)]

        return MenubarProjectSectionSnapshot(
            section: AppStateStore.ProjectSection(
                id: "/tmp/A",
                displayName: "A",
                latestUpdatedAt: root.activityUpdatedAt,
                threads: [root]
            ),
            threads: [rootSnapshot],
            threadGroups: threadGroups
        )
    }

    private func threadRow(
        id: String,
        title: String,
        updatedAt: Int,
        status: AppStateStore.ThreadStatus = .idle,
        isSubagent: Bool = false,
        parentThreadID: String? = nil,
        agentNickname: String? = nil,
        cwd: String = "/tmp/A/work"
    ) -> AppStateStore.ThreadRow {
        AppStateStore.ThreadRow(
            id: id,
            displayTitle: title,
            preview: "Preview \(id)",
            cwd: cwd,
            isSubagent: isSubagent,
            parentThreadID: parentThreadID,
            agentNickname: agentNickname,
            status: status,
            listedStatus: status,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
            isWatched: true,
            pendingRequestKind: nil,
            pendingRequestReason: nil,
            activeTurnID: status == .running ? "turn-1" : nil,
            lastTerminalActivityAt: nil
        )
    }
}
