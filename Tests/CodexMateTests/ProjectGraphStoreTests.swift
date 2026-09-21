import Combine
import XCTest
@testable import CodexMate

final class ProjectGraphStoreTests: XCTestCase {
    @MainActor
    func testNonGitProjectShowsOnlyItsLinkedChatsAndCanRefreshAsGit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphProject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "ProjectGraphStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectGraphStore(defaults: defaults)
        defer { store.setVisible(false) }
        func thread(_ id: String, cwd: String, updated: TimeInterval, subagent: Bool = false) -> AppStateStore.ThreadRow {
            .init(id: id, displayTitle: id, preview: "", cwd: cwd, isSubagent: subagent,
                  status: .idle, listedStatus: .idle, updatedAt: Date(timeIntervalSince1970: updated),
                  isWatched: false, pendingRequestKind: nil, pendingRequestReason: nil,
                  activeTurnID: nil, lastTerminalActivityAt: nil)
        }
        store.update(catalog: .init(
            workspaceRoots: [.init(path: directory.path, displayName: "Project")],
            threadWorkspaceRootHints: ["assigned": directory.path]
        ), threads: [
            thread("older", cwd: directory.path, updated: 1),
            thread("newer", cwd: directory.appendingPathComponent("src").path, updated: 2),
            thread("other-project", cwd: directory.path + "-other", updated: 3),
            thread("subagent", cwd: directory.path, updated: 4, subagent: true),
            thread("assigned", cwd: directory.path + "-chat", updated: 5)
        ], language: .english, sourceError: nil)

        let loaded = expectation(description: "Non-Git project loaded")
        let observation = store.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        store.setVisible(true)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertTrue(store.isNonGitProject)
        XCTAssertNil(store.error)
        XCTAssertNil(store.snapshot)
        XCTAssertNil(store.worktreePath)
        XCTAssertTrue(store.changes.isEmpty)
        XCTAssertEqual(store.linkedThreads.map(\.id), ["assigned", "newer", "older"])

        // Git initialization is confined to this temporary test fixture.
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory.path, "init", "-b", "main"]
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        let refreshed = expectation(description: "Git project loaded")
        let refreshObservation = store.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in refreshed.fulfill() }
        defer { refreshObservation.cancel() }
        store.refresh()
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertFalse(store.isNonGitProject)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.snapshot?.worktrees.count, 1)
        XCTAssertNotNil(store.selectedWorktree)
        XCTAssertEqual(store.linkedThreads.map(\.id), ["assigned", "newer", "older"])

        store.setVisible(false)
        store.selectProject(nil)
        XCTAssertFalse(store.isNonGitProject)
        XCTAssertTrue(store.linkedThreads.isEmpty)
    }

    @MainActor
    func testProjectAssignmentsIncludeExternalChatsWithoutMixingWorktrees() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GraphAssignments-\(UUID().uuidString)")
        let repository = directory.appendingPathComponent("repository")
        let worktree = directory.appendingPathComponent("feature")
        let otherProject = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repository.path] + arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitCommandError(message: "Git fixture command failed: \(arguments)")
            }
        }
        try git(["init", "-b", "main"])
        try git(["-c", "user.name=Graph Test", "-c", "user.email=graph@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial"])
        try git(["worktree", "add", "-b", "feature", worktree.path])

        let suite = "ProjectGraphStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectGraphStore(defaults: defaults)
        defer { store.setVisible(false) }
        func thread(_ id: String, cwd: URL, updated: TimeInterval, subagent: Bool = false) -> AppStateStore.ThreadRow {
            .init(id: id, displayTitle: id, preview: "", cwd: cwd.path, isSubagent: subagent,
                  status: .idle, listedStatus: .idle, updatedAt: Date(timeIntervalSince1970: updated),
                  isWatched: false, pendingRequestKind: nil, pendingRequestReason: nil,
                  activeTurnID: nil, lastTerminalActivityAt: nil)
        }
        let threads = [
            thread("native", cwd: repository, updated: 1),
            thread("assigned", cwd: directory.appendingPathComponent("new-chat"), updated: 2),
            thread("worktree", cwd: worktree, updated: 3),
            thread("moved-away", cwd: repository, updated: 4),
            thread("projectless", cwd: repository, updated: 5),
            thread("subagent", cwd: repository, updated: 6, subagent: true)
        ]
        let roots: [CodexDesktopProjectCatalog.WorkspaceRoot] = [
            .init(path: repository.path, displayName: "Project"),
            .init(path: otherProject.path, displayName: "Other")
        ]
        var hints = ["assigned": repository.path, "worktree": repository.path, "moved-away": otherProject.path]
        store.update(catalog: .init(workspaceRoots: roots, threadWorkspaceRootHints: hints,
                                    projectlessThreadIDs: ["projectless"]),
                     threads: threads, language: .english, sourceError: nil)
        store.selectProject(repository.path)
        let loaded = expectation(description: "Git worktrees loaded")
        let observation = store.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        store.setVisible(true)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.snapshot?.worktrees.count, 2)
        XCTAssertEqual(store.linkedThreads.map(\.id), ["assigned", "native"])

        store.selectWorktree(worktree.path)
        XCTAssertEqual(store.linkedThreads.map(\.id), ["worktree"])
        store.selectWorktree(repository.path)

        var updateCount = 0
        let catalogObservation = store.objectWillChange.sink { updateCount += 1 }
        defer { catalogObservation.cancel() }
        hints["assigned"] = otherProject.path
        store.update(catalog: .init(workspaceRoots: roots, threadWorkspaceRootHints: hints,
                                    projectlessThreadIDs: ["projectless"]),
                     threads: threads, language: .english, sourceError: nil)
        XCTAssertGreaterThan(updateCount, 0, "A project reassignment must refresh the visible chat list")
        XCTAssertEqual(store.linkedThreads.map(\.id), ["native"])
    }

    @MainActor
    func testRetainedWorktreeLabelsUseTheirSnapshotAfterProjectSwitch() throws {
        let suite = "ProjectGraphStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectGraphStore(defaults: defaults)
        store.update(catalog: .init(workspaceRoots: [
            .init(path: "/projects/OnText", displayName: "OnText"),
            .init(path: "/projects/CodexMate", displayName: "CodexMate")
        ]), threads: [], language: .english, sourceError: nil)
        store.selectProject("/projects/OnText")

        let worktrees = ["/projects/OnText", "/worktrees/settings/OnText", "/worktrees/search/OnText"].enumerated().map {
            GitWorktree(path: $0.element, head: "a", branch: "main", isMain: $0.offset == 0,
                        isLocked: false, isPrunable: false)
        }
        let renderedSnapshot = GitRepositorySnapshot(worktrees: worktrees, references: [], commits: [], loadedAt: Date())
        // Model a SwiftUI row retained while the next project's data is not yet loaded.
        let renderedNames = { worktrees.map { store.worktreeName($0, in: renderedSnapshot) } }
        let expected = [store.text("original"), "settings", "search"]
        XCTAssertEqual(renderedNames(), expected)

        store.selectProject("/projects/CodexMate")
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(renderedNames(), expected)

        store.selectProject(nil)
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(renderedNames(), expected)
    }
}
