import Foundation

enum CodexDesktopWorktreePath {
    static func normalize(path: String) -> String {
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    static func fallbackDisplayName(for path: String) -> String {
        let normalizedPath = normalize(path: path)
        guard !normalizedPath.isEmpty else {
            return CodexDesktopProjectCatalog.unknownProjectDisplayName
        }

        let component = URL(fileURLWithPath: normalizedPath).lastPathComponent
        return component.isEmpty ? normalizedPath : component
    }

    static func matches(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }
}

struct CodexDesktopWorktreeParser {
    func parse(_ data: Data) throws -> [CodexDesktopProjectCatalog.WorkspaceRoot] {
        let state = try JSONDecoder().decode(GlobalStateFile.self, from: data)
        let normalizedLabels = normalizedLabelsByPath(from: state.workspaceRootLabels)
        var seenPaths: Set<String> = []
        var roots: [CodexDesktopProjectCatalog.WorkspaceRoot] = []

        for rawPath in state.savedWorkspaceRoots {
            let normalizedPath = CodexDesktopWorktreePath.normalize(path: rawPath)
            guard !normalizedPath.isEmpty else { continue }
            guard seenPaths.insert(normalizedPath).inserted else { continue }

            roots.append(
                CodexDesktopProjectCatalog.WorkspaceRoot(
                    path: normalizedPath,
                    displayName: normalizedLabels[normalizedPath]
                        ?? CodexDesktopWorktreePath.fallbackDisplayName(for: normalizedPath)
                )
            )
        }

        return roots
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
}

private struct GlobalStateFile: Decodable {
    let savedWorkspaceRoots: [String]
    let workspaceRootLabels: [String: String]

    enum CodingKeys: String, CodingKey {
        case savedWorkspaceRoots = "electron-saved-workspace-roots"
        case workspaceRootLabels = "electron-workspace-root-labels"
    }
}
