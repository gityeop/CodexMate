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

    let workspaceRoots: [WorkspaceRoot]

    init(workspaceRoots: [WorkspaceRoot]) {
        self.workspaceRoots = workspaceRoots.sorted { lhs, rhs in
            if lhs.path.count == rhs.path.count {
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }

            return lhs.path.count > rhs.path.count
        }
    }

    func project(for cwd: String) -> ProjectReference {
        let normalizedCWD = Self.normalize(path: cwd)

        if let matchedRoot = workspaceRoots.first(where: { Self.matches(root: $0.path, path: normalizedCWD) }) {
            return ProjectReference(id: matchedRoot.path, displayName: matchedRoot.displayName)
        }

        if normalizedCWD.isEmpty {
            return ProjectReference(id: "unknown", displayName: "Unknown Project")
        }

        return ProjectReference(
            id: normalizedCWD,
            displayName: Self.fallbackDisplayName(for: normalizedCWD)
        )
    }

    static func normalize(path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func fallbackDisplayName(for path: String) -> String {
        let normalizedPath = normalize(path: path)
        guard !normalizedPath.isEmpty else { return "Unknown Project" }

        let component = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return component.isEmpty ? normalizedPath : component
    }

    private static func matches(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

struct CodexDesktopProjectCatalogReader {
    private let fileManager: FileManager
    private let codexDirectoryURLOverride: URL?
    private let codexDirectoryURLProvider: @Sendable () -> URL
    private let cache = ProjectCatalogCache()

    init(
        fileManager: FileManager = .default,
        codexDirectoryURLOverride: URL? = nil,
        codexDirectoryURLProvider: (@Sendable () -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.codexDirectoryURLOverride = codexDirectoryURLOverride
        self.codexDirectoryURLProvider = codexDirectoryURLProvider ?? {
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
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
        let state = try JSONDecoder().decode(GlobalStateFile.self, from: data)

        let normalizedLabels = Dictionary(
            uniqueKeysWithValues: state.workspaceRootLabels.map { key, value in
                (CodexDesktopProjectCatalog.normalize(path: key), value)
            }
        )

        let roots = state.savedWorkspaceRoots.map { rawPath in
            let normalizedPath = CodexDesktopProjectCatalog.normalize(path: rawPath)
            let label = normalizedLabels[normalizedPath]?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return CodexDesktopProjectCatalog.WorkspaceRoot(
                path: normalizedPath,
                displayName: (label?.isEmpty == false)
                    ? label!
                    : CodexDesktopProjectCatalog.fallbackDisplayName(for: normalizedPath)
            )
        }

        let catalog = CodexDesktopProjectCatalog(workspaceRoots: roots)
        cache.store(
            catalog,
            for: fileURL.path,
            modificationDate: modificationDate,
            fileSize: fileSize
        )
        return catalog
    }
}

private struct GlobalStateFile: Decodable {
    let savedWorkspaceRoots: [String]
    let workspaceRootLabels: [String: String]

    enum CodingKeys: String, CodingKey {
        case savedWorkspaceRoots = "electron-saved-workspace-roots"
        case workspaceRootLabels = "electron-workspace-root-labels"
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
