import Foundation

enum CodexDesktopWorktreePath {
    static func normalize(path: String) -> String {
        guard !path.isEmpty else { return "" }
        let standardizedPath = (path as NSString)
            .standardizingPath
            .precomposedStringWithCanonicalMapping
        guard standardizedPath.count > 1, standardizedPath.hasSuffix("/") else {
            return standardizedPath
        }

        return String(standardizedPath.dropLast())
    }

    static func inferredDisplayName(for path: String) -> String {
        let normalizedPath = normalize(path: path)
        guard !normalizedPath.isEmpty else {
            return CodexDesktopProjectCatalog.unknownProjectDisplayName
        }

        let component = (normalizedPath as NSString).lastPathComponent
        return component.isEmpty ? normalizedPath : component
    }

    static func matches(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

struct CodexDesktopWorktreeParser {
    struct ParsedState: Equatable {
        let workspaceRoots: [CodexDesktopProjectCatalog.WorkspaceRoot]
        let threadWorkspaceRootHints: [String: String]
        let projectlessThreadIDs: Set<String>
    }

    func parse(_ data: Data) throws -> ParsedState {
        let state = try JSONDecoder().decode(GlobalStateFile.self, from: data)
        let normalizedLabels = normalizedLabelsByPath(from: state.workspaceRootLabels ?? [:])
        let normalizedThreadWorkspaceRootHints = normalizedThreadWorkspaceRootHints(
            from: state.threadWorkspaceRootHints ?? [:]
        )
        let projectlessThreadIDs = Set((state.projectlessThreadIDs ?? []).filter { !$0.isEmpty })
        var seenPaths: Set<String> = []
        var roots: [CodexDesktopProjectCatalog.WorkspaceRoot] = []

        appendWorkspaceRoots(
            state.savedWorkspaceRoots ?? [],
            labelsByPath: normalizedLabels,
            seenPaths: &seenPaths,
            roots: &roots
        )
        appendRemoteProjectRoots(
            state.remoteProjects ?? [],
            seenPaths: &seenPaths,
            roots: &roots
        )

        return ParsedState(
            workspaceRoots: roots,
            threadWorkspaceRootHints: normalizedThreadWorkspaceRootHints,
            projectlessThreadIDs: projectlessThreadIDs
        )
    }

    private func normalizedLabelsByPath(from rawLabels: [String: String]) -> [String: String] {
        var normalizedLabels: [String: String] = [:]

        for (rawPath, rawLabel) in rawLabels {
            let normalizedPath = CodexDesktopWorktreePath.normalize(path: rawPath)
            guard !normalizedPath.isEmpty else { continue }

            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }

            if normalizedLabels[normalizedPath] == nil {
                normalizedLabels[normalizedPath] = label
            }
        }

        return normalizedLabels
    }

    private func normalizedThreadWorkspaceRootHints(from rawHints: [String: String]) -> [String: String] {
        var normalizedHints: [String: String] = [:]

        for (threadID, rawPath) in rawHints {
            guard !threadID.isEmpty else { continue }

            let normalizedPath = CodexDesktopWorktreePath.normalize(path: rawPath)
            guard !normalizedPath.isEmpty else { continue }

            normalizedHints[threadID] = normalizedPath
        }

        return normalizedHints
    }

    private func appendWorkspaceRoots(
        _ rawPaths: [String],
        labelsByPath: [String: String],
        seenPaths: inout Set<String>,
        roots: inout [CodexDesktopProjectCatalog.WorkspaceRoot]
    ) {
        for rawPath in rawPaths {
            let normalizedPath = CodexDesktopWorktreePath.normalize(path: rawPath)
            guard !normalizedPath.isEmpty else { continue }
            guard seenPaths.insert(normalizedPath).inserted else { continue }

            roots.append(
                CodexDesktopProjectCatalog.WorkspaceRoot(
                    path: normalizedPath,
                    displayName: labelsByPath[normalizedPath]
                        ?? CodexDesktopWorktreePath.inferredDisplayName(for: normalizedPath)
                )
            )
        }
    }

    private func appendRemoteProjectRoots(
        _ remoteProjects: [RemoteProject],
        seenPaths: inout Set<String>,
        roots: inout [CodexDesktopProjectCatalog.WorkspaceRoot]
    ) {
        for remoteProject in remoteProjects {
            let normalizedPath = CodexDesktopWorktreePath.normalize(path: remoteProject.remotePath)
            guard !normalizedPath.isEmpty else { continue }
            guard seenPaths.insert(normalizedPath).inserted else { continue }

            let trimmedLabel = remoteProject.label?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName: String
            if let trimmedLabel, !trimmedLabel.isEmpty {
                displayName = trimmedLabel
            } else {
                displayName = CodexDesktopWorktreePath.inferredDisplayName(for: normalizedPath)
            }

            roots.append(
                CodexDesktopProjectCatalog.WorkspaceRoot(
                    path: normalizedPath,
                    displayName: displayName
                )
            )
        }
    }
}

private struct GlobalStateFile: Decodable {
    let savedWorkspaceRoots: [String]?
    let workspaceRootLabels: [String: String]?
    let threadWorkspaceRootHints: [String: String]?
    let projectlessThreadIDs: [String]?
    let remoteProjects: [RemoteProject]?

    enum CodingKeys: String, CodingKey {
        case savedWorkspaceRoots = "electron-saved-workspace-roots"
        case workspaceRootLabels = "electron-workspace-root-labels"
        case threadWorkspaceRootHints = "thread-workspace-root-hints"
        case projectlessThreadIDs = "projectless-thread-ids"
        case remoteProjects = "remote-projects"
    }
}

private struct RemoteProject: Decodable {
    let remotePath: String
    let label: String?
}
