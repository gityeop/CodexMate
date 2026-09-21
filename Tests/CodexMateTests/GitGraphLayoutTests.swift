import XCTest
@testable import CodexMate

final class GitGraphLayoutTests: XCTestCase {
    func testRepeatedCodexCheckoutNamesUseDistinctWorktreeDirectories() {
        let worktrees = ["/worktrees/0aca/OnText", "/worktrees/ontext-settings/OnText", "/projects/release"].map {
            GitWorktree(path: $0, head: "a", branch: nil, isMain: false, isLocked: false, isPrunable: false)
        }
        let snapshot = GitRepositorySnapshot(worktrees: worktrees, references: [], commits: [], loadedAt: Date())
        XCTAssertEqual(worktrees.map { snapshot.displayName(for: $0) }, ["0aca", "ontext-settings", "release"])
    }

    func testMergeSplitsIntoParentsAndConvergesAtCommonAncestor() throws {
        let commits = [commit("merge", ["left", "right"]), commit("left", ["base"]), commit("right", ["base"]), commit("base", [])]
        let graph = GitGraphLayout(commits: commits)
        XCTAssertEqual(graph.columnCount, 2)
        XCTAssertEqual(graph.rows[0].segments.filter(\.startsAtNode).count, 2)
        XCTAssertEqual(Set(graph.rows[0].segments.filter(\.startsAtNode).map(\.to)), [0, 1])
        XCTAssertEqual(graph.rows[2].segments.first(where: \.startsAtNode)?.to, graph.rows[3].column)
        XCTAssertTrue(graph.rows[3].segments.contains(where: \.endsAtNode))
        XCTAssertFalse(graph.rows[3].segments.contains(where: \.startsAtNode))
        // Every continuation at one row's bottom has an incoming path at the next row's top.
        for index in 0..<(graph.rows.count - 1) {
            let bottom = Set(graph.rows[index].segments.filter { !$0.endsAtNode }.map(\.to))
            let top = Set(graph.rows[index + 1].segments.filter { !$0.startsAtNode }.map(\.from))
            XCTAssertEqual(bottom, top)
        }
    }

    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "Test", date: Date())
    }
}
