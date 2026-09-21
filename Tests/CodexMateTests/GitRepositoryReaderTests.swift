import Foundation
import XCTest
@testable import CodexMate

final class GitRepositoryReaderTests: XCTestCase {
    private var directory: URL!
    private var repository: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexMateGitTests-\(UUID().uuidString)")
        repository = directory.appendingPathComponent("repository with spaces")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Graph Test"])
        try git(["config", "user.email", "graph@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testIncludesDetachedWorktreeHistoryAndMergedParents() async throws {
        try write("base", to: "base.txt")
        try git(["add", "."])
        try git(["commit", "-m", "Base"])
        let base = try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let feature = directory.appendingPathComponent("설정 화면")
        let detached = directory.appendingPathComponent("detached work")
        try git(["worktree", "add", "-b", "feature/settings", feature.path])
        try git(["worktree", "add", "--detach", detached.path])
        try "settings".write(to: feature.appendingPathComponent("settings.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], at: feature)
        try git(["commit", "-m", "Settings"], at: feature)
        try "ai".write(to: detached.appendingPathComponent("ai.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], at: detached)
        try git(["commit", "-m", "Detached AI work"], at: detached)
        let detachedHead = try git(["rev-parse", "HEAD"], at: detached).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["merge", "--no-ff", "feature/settings", "-m", "Merge settings"])

        let snapshot = try await GitRepositoryReader().load(at: repository.path)
        XCTAssertEqual(snapshot.worktrees.count, 3)
        XCTAssertEqual(snapshot.references.filter { !$0.isRemote }.count, 2)
        XCTAssertEqual(snapshot.worktrees.first?.branch, "main")
        let detachedWorktree = try XCTUnwrap(snapshot.worktrees.first { $0.head == detachedHead })
        XCTAssertNil(detachedWorktree.branch)
        XCTAssertTrue(snapshot.commits.contains { $0.id == detachedHead })
        XCTAssertTrue(snapshot.commits.contains { $0.id == base })
        XCTAssertEqual(snapshot.commits.first { $0.subject == "Merge settings" }?.parents.count, 2)
        for (index, commit) in snapshot.commits.enumerated() {
            for parent in commit.parents {
                XCTAssertGreaterThan(try XCTUnwrap(snapshot.commits.firstIndex { $0.id == parent }), index)
            }
        }
        let graph = GitGraphLayout(commits: snapshot.commits)
        XCTAssertEqual(graph.rows.count, snapshot.commits.count)
        XCTAssertGreaterThan(graph.columnCount, 1)
    }

    func testStatusPreservesRenameAndUnusualFilenames() async throws {
        try write("original", to: "old name.txt")
        try git(["add", "."])
        try git(["commit", "-m", "Initial"])
        try git(["mv", "old name.txt", "새 이름.txt"])
        try write("untracked", to: "line\nbreak.txt")
        let changes = try await GitRepositoryReader().changes(at: repository.path)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes.first { $0.path == "새 이름.txt" }?.originalPath, "old name.txt")
        XCTAssertEqual(changes.first { $0.path == "line\nbreak.txt" }?.status, "??")
    }

    func testUnbornRepositoryHasWorktreeAndEmptyGraph() async throws {
        let snapshot = try await GitRepositoryReader().load(at: repository.path)
        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertEqual(snapshot.worktrees.first?.branch, "main")
        XCTAssertTrue(snapshot.commits.isEmpty)
    }

    func testNonRepositoryIsIdentifiedSeparately() async throws {
        do {
            _ = try await GitRepositoryReader().load(at: directory.path)
            XCTFail("Expected a non-Git project")
        } catch GitRepositoryError.notRepository {
            // An existing ordinary folder is a supported project type.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingDirectoryStillSurfacesGitError() async throws {
        let missing = directory.appendingPathComponent("missing-project").path
        do {
            _ = try await GitRepositoryReader().load(at: missing)
            XCTFail("Expected Git failure")
        } catch let error as GitCommandError {
            XCTAssertTrue(error.localizedDescription.contains("cannot change to"))
            XCTAssertTrue(error.localizedDescription.contains(missing))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMalformedOutputThrowsInsteadOfReturningEmptyData() {
        XCTAssertThrowsError(try GitRepositoryReader.parseWorktrees("unexpected"))
        XCTAssertThrowsError(try GitRepositoryReader.parseCommits("truncated\0record"))
        XCTAssertThrowsError(try GitRepositoryReader.parseChanges("R  new.txt\0"))
    }

    private func write(_ content: String, to filename: String) throws {
        try content.write(to: repository.appendingPathComponent(filename), atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: [String], at path: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (path ?? repository).path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw GitCommandError(message: text) }
        return text
    }
}
