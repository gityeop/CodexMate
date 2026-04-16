import XCTest
@testable import CodexMate

final class CodexDesktopProjectCatalogReaderTests: XCTestCase {
    func testLoadUsesProvidedCodexDirectory() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectoryURL = tempDirectoryURL.appending(path: "custom-codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        try writeGlobalState(
            to: codexDirectoryURL,
            contents: """
            {
              "electron-saved-workspace-roots": [
                "/tmp/workspace-a",
                "/tmp/workspace-b/nested"
              ],
              "electron-workspace-root-labels": {
                "/tmp/workspace-b/nested": "  Nested Label  "
              }
            }
            """
        )

        let reader = CodexDesktopProjectCatalogReader(
            codexDirectoryURLProvider: { codexDirectoryURL }
        )

        let catalog = try reader.load()

        XCTAssertEqual(catalog.project(for: "/tmp/workspace-b/nested/project").displayName, "Nested Label")
        XCTAssertEqual(catalog.project(for: "/tmp/workspace-a/service").displayName, "workspace-a")
    }

    func testCodexDirectoryOverrideTakesPrecedenceOverProvider() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let overrideDirectoryURL = tempDirectoryURL.appending(path: "override-codex-home", directoryHint: .isDirectory)
        let providerDirectoryURL = tempDirectoryURL.appending(path: "provider-codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: overrideDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        try writeGlobalState(
            to: overrideDirectoryURL,
            contents: """
            {
              "electron-saved-workspace-roots": [
                "/tmp/override-workspace"
              ],
              "electron-workspace-root-labels": {
                "/tmp/override-workspace": "Override Label"
              }
            }
            """
        )
        try writeGlobalState(
            to: providerDirectoryURL,
            contents: """
            {
              "electron-saved-workspace-roots": [
                "/tmp/provider-workspace"
              ],
              "electron-workspace-root-labels": {
                "/tmp/provider-workspace": "Provider Label"
              }
            }
            """
        )

        let reader = CodexDesktopProjectCatalogReader(
            codexDirectoryURLOverride: overrideDirectoryURL,
            codexDirectoryURLProvider: { providerDirectoryURL }
        )

        let catalog = try reader.load()

        XCTAssertEqual(catalog.project(for: "/tmp/override-workspace/app").displayName, "Override Label")
    }

    func testWorktreeParserNormalizesDeduplicatesRootsAndTrimsLabels() throws {
        let parser = CodexDesktopWorktreeParser()
        let data = try XCTUnwrap(
            """
            {
              "electron-saved-workspace-roots": [
                "/tmp/worktrees/app",
                "/tmp/worktrees/../worktrees/app",
                "/tmp/worktrees/feature"
              ],
              "electron-workspace-root-labels": {
                "/tmp/worktrees/app": "  App Root  ",
                "/tmp/worktrees/../worktrees/feature": "  Feature Root  "
              }
            }
            """.data(using: .utf8)
        )

        let parsedState = try parser.parse(data)

        XCTAssertEqual(
            parsedState.workspaceRoots,
            [
                .init(path: "/tmp/worktrees/app", displayName: "App Root"),
                .init(path: "/tmp/worktrees/feature", displayName: "Feature Root")
            ]
        )
        XCTAssertTrue(parsedState.threadWorkspaceRootHints.isEmpty)
        XCTAssertTrue(parsedState.projectlessThreadIDs.isEmpty)
    }

    func testWorktreeParserAcceptsNullLabelsAndPreservesThreadWorkspaceHints() throws {
        let parser = CodexDesktopWorktreeParser()
        let data = try XCTUnwrap(
            """
            {
              "electron-saved-workspace-roots": [
                "/Users/tester/문서/Coding/guldin_keyboard/guldin"
              ],
              "electron-workspace-root-labels": null,
              "thread-workspace-root-hints": {
                "thread-1": "/Users/tester/문서/Coding/guldin_keyboard/guldin"
              }
            }
            """.data(using: .utf8)
        )

        let parsedState = try parser.parse(data)

        XCTAssertEqual(
            parsedState.workspaceRoots,
            [
                .init(
                    path: "/Users/tester/문서/Coding/guldin_keyboard/guldin",
                    displayName: "guldin"
                )
            ]
        )
        XCTAssertEqual(
            parsedState.threadWorkspaceRootHints,
            [
                "thread-1": "/Users/tester/문서/Coding/guldin_keyboard/guldin"
            ]
        )
    }

    func testWorktreeParserDeduplicatesUnicodeEquivalentRoots() throws {
        let parser = CodexDesktopWorktreeParser()
        let decomposed = "/Users/tester/문서/Coding/guldin"
        let composed = "/Users/tester/문서/Coding/guldin"
        let data = try XCTUnwrap(
            """
            {
              "electron-saved-workspace-roots": [
                "\(decomposed)",
                "\(composed)"
              ],
              "electron-workspace-root-labels": {
                "\(decomposed)": "Guldin"
              }
            }
            """.data(using: .utf8)
        )

        let parsedState = try parser.parse(data)

        XCTAssertEqual(
            parsedState.workspaceRoots,
            [
                .init(path: composed, displayName: "Guldin")
            ]
        )
    }

    func testWorktreeParserFallsBackToFolderNameWhenLabelIsBlank() throws {
        let parser = CodexDesktopWorktreeParser()
        let data = try XCTUnwrap(
            """
            {
              "electron-saved-workspace-roots": [
                "/tmp/worktrees/parser-menu"
              ],
              "electron-workspace-root-labels": {
                "/tmp/worktrees/parser-menu": "   "
              }
            }
            """.data(using: .utf8)
        )

        let parsedState = try parser.parse(data)

        XCTAssertEqual(
            parsedState.workspaceRoots,
            [
                .init(path: "/tmp/worktrees/parser-menu", displayName: "parser-menu")
            ]
        )
    }

    func testWorktreeParserReadsThreadWorkspaceRootHintsAndProjectlessThreadIDs() throws {
        let parser = CodexDesktopWorktreeParser()
        let data = try XCTUnwrap(
            """
            {
              "electron-saved-workspace-roots": [
                "/tmp/workspaces/codextension"
              ],
              "electron-workspace-root-labels": {},
              "thread-workspace-root-hints": {
                "thread-1": "/tmp/workspaces/codextension",
                "thread-2": "/tmp/workspaces/../workspaces/codextension"
              },
              "projectless-thread-ids": [
                "chat-1",
                "chat-2"
              ]
            }
            """.data(using: .utf8)
        )

        let parsedState = try parser.parse(data)

        XCTAssertEqual(
            parsedState.threadWorkspaceRootHints,
            [
                "thread-1": "/tmp/workspaces/codextension",
                "thread-2": "/tmp/workspaces/codextension"
            ]
        )
        XCTAssertEqual(parsedState.projectlessThreadIDs, ["chat-1", "chat-2"])
    }

    func testCatalogUsesThreadWorkspaceRootHintBeforeWorktreeCWD() {
        let catalog = CodexDesktopProjectCatalog(
            workspaceRoots: [
                .init(path: "/tmp/workspaces/codextension", displayName: "codextension")
            ],
            threadWorkspaceRootHints: [
                "thread-1": "/tmp/workspaces/codextension"
            ]
        )

        let project = catalog.project(
            forThreadID: "thread-1",
            cwd: "/tmp/.codex/worktrees/3a2e/codextension"
        )

        XCTAssertEqual(project.id, "/tmp/workspaces/codextension")
        XCTAssertEqual(project.displayName, "codextension")
    }

    func testCatalogMatchesUnicodeEquivalentWorkspacePath() {
        let catalog = CodexDesktopProjectCatalog(
            workspaceRoots: [
                .init(path: "/Users/tester/문서/Coding/guldin", displayName: "guldin")
            ]
        )

        let project = catalog.project(
            forThreadID: "thread-1",
            cwd: "/Users/tester/문서/Coding/guldin/worktree"
        )

        XCTAssertEqual(project.id, "/Users/tester/문서/Coding/guldin")
        XCTAssertEqual(project.displayName, "guldin")
    }

    func testCatalogPlacesProjectlessThreadsInChatsProject() {
        let catalog = CodexDesktopProjectCatalog(
            workspaceRoots: [
                .init(path: "/tmp/workspaces/codextension", displayName: "codextension")
            ],
            projectlessThreadIDs: ["chat-1"]
        )

        let project = catalog.project(
            forThreadID: "chat-1",
            cwd: "/tmp/.codex/threads"
        )

        XCTAssertEqual(project.id, CodexDesktopProjectCatalog.chatsProjectID)
        XCTAssertEqual(project.displayName, CodexDesktopProjectCatalog.chatsProjectDisplayName)
    }

    func testCatalogMatchesWorkspaceOnlyAtDirectoryBoundary() {
        let catalog = CodexDesktopProjectCatalog(
            workspaceRoots: [
                .init(path: "/tmp/worktrees/app", displayName: "App")
            ]
        )

        XCTAssertEqual(
            catalog.project(for: "/tmp/worktrees/app/feature").displayName,
            "App"
        )
        XCTAssertEqual(
            catalog.project(for: "/tmp/worktrees/app-copy").displayName,
            CodexDesktopProjectCatalog.unknownProjectDisplayName
        )
    }

    private func writeGlobalState(to codexDirectoryURL: URL, contents: String) throws {
        let data = try XCTUnwrap(contents.data(using: .utf8))
        try data.write(
            to: codexDirectoryURL.appendingPathComponent(".codex-global-state.json", isDirectory: false)
        )
    }
}
