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

    private func writeGlobalState(to codexDirectoryURL: URL, contents: String) throws {
        let data = try XCTUnwrap(contents.data(using: .utf8))
        try data.write(
            to: codexDirectoryURL.appendingPathComponent(".codex-global-state.json", isDirectory: false)
        )
    }
}
