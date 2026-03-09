import Foundation

struct CodexDesktopProjectCatalog: Equatable {
    struct Project: Equatable {
        let id: String
        let displayName: String
    }

    static let empty = Self(savedRoots: [], labelsByRoot: [:])

    private struct Entry: Equatable {
        let rootPath: String
        let displayName: String
        let depth: Int
    }

    private let entries: [Entry]
    private let savedProjects: [Project]

    init(savedRoots: [String], activeRoots: [String] = [], labelsByRoot: [String: String]) {
        let canonicalLabels = labelsByRoot.reduce(into: [String: String]()) { result, pair in
            let canonicalRoot = Self.canonicalPath(pair.key)
            let trimmedLabel = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !canonicalRoot.isEmpty, !trimmedLabel.isEmpty else { return }
            result[canonicalRoot] = trimmedLabel
        }

        var deduplicatedEntries: [String: Entry] = [:]
        var savedProjectEntries: [Project] = []

        let orderedRoots = Self.uniquePaths(activeRoots + savedRoots)

        for root in orderedRoots {
            let canonicalRoot = Self.canonicalPath(root)
            guard !canonicalRoot.isEmpty, deduplicatedEntries[canonicalRoot] == nil else { continue }

            let displayName = canonicalLabels[canonicalRoot] ?? Self.fallbackDisplayName(for: canonicalRoot)
            deduplicatedEntries[canonicalRoot] = Entry(
                rootPath: canonicalRoot,
                displayName: displayName,
                depth: Self.pathDepth(canonicalRoot)
            )
            savedProjectEntries.append(Project(id: canonicalRoot, displayName: displayName))
        }

        entries = deduplicatedEntries.values.sorted { lhs, rhs in
            if lhs.depth == rhs.depth {
                return lhs.rootPath.localizedStandardCompare(rhs.rootPath) == .orderedAscending
            }

            return lhs.depth > rhs.depth
        }
        savedProjects = savedProjectEntries
    }

    func project(for cwd: String) -> Project {
        let canonicalCWD = Self.canonicalPath(cwd)

        if let entry = entries.first(where: { Self.isSameOrDescendant(path: canonicalCWD, root: $0.rootPath) }) {
            return Project(id: entry.rootPath, displayName: entry.displayName)
        }

        if canonicalCWD.isEmpty {
            return Project(id: "__unknown_project__", displayName: "Unknown Project")
        }

        return Project(id: canonicalCWD, displayName: Self.fallbackDisplayName(for: canonicalCWD))
    }

    static func canonicalPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        return URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    static func fallbackDisplayName(for path: String) -> String {
        let canonicalPath = canonicalPath(path)
        guard !canonicalPath.isEmpty else { return "Unknown Project" }

        let folderName = URL(fileURLWithPath: canonicalPath).lastPathComponent
        return folderName.isEmpty ? canonicalPath : folderName
    }

    private static func isSameOrDescendant(path: String, root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty else { return false }
        if path == root { return true }
        if root == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(root + "/")
    }

    private static func pathDepth(_ path: String) -> Int {
        if path == "/" {
            return 1
        }

        return path.split(separator: "/").count
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for path in paths {
            let canonicalPath = canonicalPath(path)
            guard !canonicalPath.isEmpty, !seen.contains(canonicalPath) else { continue }
            seen.insert(canonicalPath)
            result.append(canonicalPath)
        }

        return result
    }

    var allProjectsForBadges: [Project] {
        savedProjects
    }

    var savedProjectCount: Int {
        savedProjects.count
    }
}

struct CodexDesktopProjectStateReader {
    private let globalStateURL: URL

    init(
        fileManager: FileManager = .default,
        globalStateURL: URL? = nil
    ) {
        self.globalStateURL = globalStateURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(".codex-global-state.json", isDirectory: false)
    }

    func readCatalog() throws -> CodexDesktopProjectCatalog {
        let data = try Data(contentsOf: globalStateURL)
        let state = try JSONDecoder().decode(GlobalState.self, from: data)
        return CodexDesktopProjectCatalog(
            savedRoots: state.savedWorkspaceRoots,
            activeRoots: state.activeWorkspaceRoots,
            labelsByRoot: state.workspaceRootLabels
        )
    }

    private struct GlobalState: Decodable {
        let savedWorkspaceRoots: [String]
        let activeWorkspaceRoots: [String]
        let workspaceRootLabels: [String: String]

        private enum CodingKeys: String, CodingKey {
            case savedWorkspaceRoots = "electron-saved-workspace-roots"
            case activeWorkspaceRoots = "active-workspace-roots"
            case workspaceRootLabels = "electron-workspace-root-labels"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            savedWorkspaceRoots = try container.decodeIfPresent([String].self, forKey: .savedWorkspaceRoots) ?? []
            activeWorkspaceRoots = try container.decodeIfPresent([String].self, forKey: .activeWorkspaceRoots) ?? []
            workspaceRootLabels = try container.decodeIfPresent([String: String].self, forKey: .workspaceRootLabels) ?? [:]
        }
    }
}
