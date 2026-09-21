import Foundation

struct GitWorktree: Equatable, Identifiable, Sendable {
    let path: String
    let head: String
    let branch: String?
    let isMain: Bool
    let isLocked: Bool
    let isPrunable: Bool

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct GitReference: Equatable, Sendable {
    let name: String
    let commitID: String
    let isRemote: Bool
}

struct GitCommit: Equatable, Identifiable, Sendable {
    let id: String
    let parents: [String]
    let subject: String
    let author: String
    let date: Date
}

struct GitFileChange: Equatable, Identifiable, Sendable {
    let path: String
    let status: String
    let originalPath: String?
    var id: String { path }
}

struct GitRepositorySnapshot: Equatable, Sendable {
    let worktrees: [GitWorktree]
    let references: [GitReference]
    let commits: [GitCommit]
    let loadedAt: Date

    func displayName(for worktree: GitWorktree) -> String {
        // Codex commonly repeats the repository's folder name under distinct worktree IDs.
        if worktrees.filter({ $0.name == worktree.name }).count > 1 {
            return URL(fileURLWithPath: worktree.path).deletingLastPathComponent().lastPathComponent
        }
        return worktree.name
    }
}

enum GitRepositoryError: Error {
    case notRepository
}

struct GitCommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
