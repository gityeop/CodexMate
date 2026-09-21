import Foundation

/// Git stays on this actor, away from AppKit's main thread. All commands are read-only.
actor GitRepositoryReader {
    static let commitLimit = 200

    func load(at path: String) async throws -> GitRepositorySnapshot {
        let worktrees = try Self.parseWorktrees(await run(at: path, ["worktree", "list", "--porcelain", "-z"]))
        let references = try Self.parseReferences(await run(at: path, [
            "for-each-ref", "--format=%(objectname)%00%(refname)", "refs/heads", "refs/remotes"
        ]))
        // --all alone omits commits reachable only through a detached worktree HEAD.
        let heads = Set(worktrees.map(\.head).filter { !$0.allSatisfy { $0 == "0" } }).sorted()
        let commits: [GitCommit]
        if heads.isEmpty && references.isEmpty {
            commits = [] // An initialized repository with no first commit yet.
        } else {
            commits = try Self.parseCommits(await run(at: path, [
                "log", "--branches", "--remotes", "--topo-order", "--max-count=\(Self.commitLimit)", "-z",
                "--format=%H%x00%P%x00%s%x00%an%x00%at"
            ] + heads + ["--"]))
        }
        return GitRepositorySnapshot(worktrees: worktrees, references: references, commits: commits, loadedAt: Date())
    }

    func changes(at path: String) async throws -> [GitFileChange] {
        try Self.parseChanges(await run(at: path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]))
    }

    private func run(at path: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try execute(process, at: path, arguments: arguments)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private func execute(_ process: Process, at path: String, arguments: [String]) throws -> String {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        if Task.isCancelled { process.terminate() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw GitCommandError(message: "git \(arguments.first ?? "") returned non-UTF-8 output: \(path)")
        }
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 128, arguments.first == "worktree",
               text.hasPrefix("fatal: not a git repository (or any of the parent directories): .git") {
                throw GitRepositoryError.notRepository
            }
            throw GitCommandError(message: "git \(arguments.joined(separator: " "))\n\(path)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    static func parseWorktrees(_ text: String) throws -> [GitWorktree] {
        var result: [GitWorktree] = []
        for record in text.components(separatedBy: "\0\0") where !record.isEmpty {
            let fields = record.components(separatedBy: "\0")
            guard let pathField = fields.first, pathField.hasPrefix("worktree ") else {
                throw GitCommandError(message: "Invalid git worktree record: \(record)")
            }
            if fields.contains("bare") { continue }
            guard let headField = fields.first(where: { $0.hasPrefix("HEAD ") }) else {
                throw GitCommandError(message: "Missing HEAD in git worktree record: \(pathField)")
            }
            let branch = fields.first(where: { $0.hasPrefix("branch refs/heads/") })
                .map { String($0.dropFirst("branch refs/heads/".count)) }
            result.append(GitWorktree(
                path: String(pathField.dropFirst(9)), head: String(headField.dropFirst(5)), branch: branch,
                isMain: result.isEmpty, isLocked: fields.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }),
                isPrunable: fields.contains(where: { $0 == "prunable" || $0.hasPrefix("prunable ") })
            ))
        }
        return result
    }

    static func parseReferences(_ text: String) throws -> [GitReference] {
        try text.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw GitCommandError(message: "Invalid git reference: \(line)") }
            let remote = fields[1].hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            return GitReference(name: String(fields[1].dropFirst(prefix.count)), commitID: String(fields[0]), isRemote: remote)
        }
    }

    static func parseCommits(_ text: String) throws -> [GitCommit] {
        guard !text.isEmpty else { return [] }
        var fields = text.components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 5) else { throw GitCommandError(message: "Invalid git log field count: \(fields.count)") }
        return try stride(from: 0, to: fields.count, by: 5).map { index in
            guard let timestamp = TimeInterval(fields[index + 4]) else {
                throw GitCommandError(message: "Invalid git commit date: \(fields[index + 4])")
            }
            return GitCommit(id: fields[index], parents: fields[index + 1].split(separator: " ").map(String.init),
                             subject: fields[index + 2], author: fields[index + 3], date: Date(timeIntervalSince1970: timestamp))
        }
    }

    static func parseChanges(_ text: String) throws -> [GitFileChange] {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [GitFileChange] = []
        var index = 0
        while index < fields.count {
            let field = fields[index]
            guard field.count >= 4 else { throw GitCommandError(message: "Invalid git status record: \(field)") }
            let status = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            let renamed = status.contains("R") || status.contains("C")
            var originalPath: String?
            if renamed {
                index += 1
                guard index < fields.count else { throw GitCommandError(message: "Missing original path in git status: \(field)") }
                originalPath = fields[index]
            }
            result.append(GitFileChange(path: path, status: status, originalPath: originalPath))
            index += 1
        }
        return result
    }
}
