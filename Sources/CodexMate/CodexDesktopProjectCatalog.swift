import Foundation

struct CodexDesktopProjectCatalog: Equatable {
    struct WorkspaceRoot: Equatable {
        let path: String
        let displayName: String
    }

    struct ProjectReference: Equatable {
        let id: String
        let displayName: String
    }

    static let empty = CodexDesktopProjectCatalog(workspaceRoots: [])
    static let chatsProjectID = "chats"
    static let chatsProjectDisplayName = "Chats"
    static let unknownProjectID = "unknown"
    static let unknownProjectDisplayName = "Unknown Project"

    let workspaceRoots: [WorkspaceRoot]
    let threadWorkspaceRootHints: [String: String]
    let projectlessThreadIDs: Set<String>

    init(
        workspaceRoots: [WorkspaceRoot],
        threadWorkspaceRootHints: [String: String] = [:],
        projectlessThreadIDs: Set<String> = []
    ) {
        self.workspaceRoots = workspaceRoots.sorted { lhs, rhs in
            if lhs.path.count == rhs.path.count {
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

            return lhs.path.count > rhs.path.count
        }
        self.threadWorkspaceRootHints = threadWorkspaceRootHints.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty else { return }

            let normalizedPath = CodexDesktopWorktreePath.normalize(path: entry.value)
            guard !normalizedPath.isEmpty else { return }

            result[entry.key] = normalizedPath
        }
        self.projectlessThreadIDs = Set(projectlessThreadIDs.filter { !$0.isEmpty })
    }

    func project(for cwd: String) -> ProjectReference {
        project(forThreadID: nil, cwd: cwd)
    }

    func project(forThreadID threadID: String?, cwd: String) -> ProjectReference {
        if let threadID, projectlessThreadIDs.contains(threadID) {
            return ProjectReference(id: Self.chatsProjectID, displayName: Self.chatsProjectDisplayName)
        }

        let normalizedCWD = normalizedProjectPath(forThreadID: threadID, cwd: cwd)

        if let matchedRoot = workspaceRoots.first(where: {
            CodexDesktopWorktreePath.matches(root: $0.path, path: normalizedCWD)
        }) {
            return ProjectReference(id: matchedRoot.path, displayName: matchedRoot.displayName)
        }

        if normalizedCWD.isEmpty {
            return ProjectReference(id: Self.unknownProjectID, displayName: Self.unknownProjectDisplayName)
        }

        // When the user has an active workspace catalog, unmatched thread paths should not
        // revive removed projects by reusing the folder name as a synthetic project section.
        if !workspaceRoots.isEmpty {
            return ProjectReference(id: Self.unknownProjectID, displayName: Self.unknownProjectDisplayName)
        }

        return ProjectReference(
            id: normalizedCWD,
            displayName: CodexDesktopWorktreePath.fallbackDisplayName(for: normalizedCWD)
        )
    }

    private func normalizedProjectPath(forThreadID threadID: String?, cwd: String) -> String {
        if let threadID, let hintedRoot = threadWorkspaceRootHints[threadID] {
            return hintedRoot
        }

        return CodexDesktopWorktreePath.normalize(path: cwd)
    }
}

struct CodexDesktopProjectCatalogReader {
    private let fileManager: FileManager
    private let codexDirectoryURLOverride: URL?
    private let codexDirectoryURLProvider: @Sendable () -> URL
    private let parser: CodexDesktopWorktreeParser
    private let cache = ProjectCatalogCache()

    init(
        fileManager: FileManager = .default,
        codexDirectoryURLOverride: URL? = nil,
        codexDirectoryURLProvider: (@Sendable () -> URL)? = nil,
        parser: CodexDesktopWorktreeParser = CodexDesktopWorktreeParser()
    ) {
        self.fileManager = fileManager
        self.codexDirectoryURLOverride = codexDirectoryURLOverride
        self.codexDirectoryURLProvider = codexDirectoryURLProvider ?? {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        self.parser = parser
    }

    func load() throws -> CodexDesktopProjectCatalog {
        let fileURL = (codexDirectoryURLOverride ?? codexDirectoryURLProvider()).standardizedFileURL
            .appendingPathComponent(".codex-global-state.json", isDirectory: false)
        let resourceValues = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modificationDate = resourceValues.contentModificationDate
        let fileSize = resourceValues.fileSize

        if let cachedCatalog = cache.value(
            for: fileURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        ) {
            return cachedCatalog
        }

        let data = try Data(contentsOf: fileURL)
        let parsedState = try parser.parse(data)
        let catalog = CodexDesktopProjectCatalog(
            workspaceRoots: parsedState.workspaceRoots,
            threadWorkspaceRootHints: parsedState.threadWorkspaceRootHints,
            projectlessThreadIDs: parsedState.projectlessThreadIDs
        )
        cache.store(
            catalog,
            for: fileURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        )
        return catalog
    }
}

private final class ProjectCatalogCache {
    private struct Entry {
        let path: String
        let modificationDate: Date?
        let fileSize: Int?
        let catalog: CodexDesktopProjectCatalog
    }

    private var entry: Entry?

    func value(for path: String, modificationDate: Date?, fileSize: Int?) -> CodexDesktopProjectCatalog? {
        guard let entry,
              entry.path == path,
              entry.modificationDate == modificationDate,
              entry.fileSize == fileSize
        else {
            return nil
        }

        return entry.catalog
    }

    func store(_ catalog: CodexDesktopProjectCatalog, for path: String, modificationDate: Date?, fileSize: Int?) {
        entry = Entry(
            path: path,
            modificationDate: modificationDate,
            fileSize: fileSize,
            catalog: catalog
        )
    }
}
