import AppKit

enum ClaudeCodeSessionLauncherError: LocalizedError {
    case openFailed

    var errorDescription: String? {
        switch self {
        case .openFailed:
            return "macOS could not open the Claude Code session."
        }
    }
}

/// Re-opens a Claude Code session in Claude Desktop, or in the user's default terminal for
/// `.command` files when Claude Desktop cannot take it.
enum ClaudeCodeSessionLauncher {
    enum Destination: Equatable {
        case claudeDesktop
        case terminal
    }

    /// Claude Desktop's resume link takes a Claude Code transcript id. It opens the Desktop session
    /// that already owns the transcript, or imports it as a new one.
    static func desktopResumeURL(sessionID: String) -> URL? {
        guard UUID(uuidString: sessionID) != nil else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }

    static func destination(sessionID: String, claudeDesktopInstalled: Bool) -> Destination {
        claudeDesktopInstalled && desktopResumeURL(sessionID: sessionID) != nil ? .claudeDesktop : .terminal
    }

    static var isClaudeDesktopInstalled: Bool {
        guard let probeURL = URL(string: "claude://") else {
            return false
        }
        return NSWorkspace.shared.urlForApplication(toOpen: probeURL) != nil
    }

    static func openInClaudeDesktop(sessionID: String) throws {
        guard let url = desktopResumeURL(sessionID: sessionID),
              NSWorkspace.shared.open(url) else {
            throw ClaudeCodeSessionLauncherError.openFailed
        }
    }

    static func resumeScript(sessionID: String, projectPath: String?) -> String {
        var command = "exec claude --resume \(shellQuoted(sessionID))"
        if let projectPath, !projectPath.isEmpty {
            command = "cd \(shellQuoted(projectPath)) && " + command
        }

        // An interactive login shell picks up the PATH users set for `claude` in their zsh config.
        return [
            "#!/bin/zsh",
            "exec /bin/zsh -ilc \(shellQuoted(command))",
            "",
        ].joined(separator: "\n")
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func resume(sessionID: String, projectPath: String?) throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexMate-ClaudeResume", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let safeSessionID = String(sessionID.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        })
        let scriptURL = directoryURL.appendingPathComponent(
            "resume-\(safeSessionID.isEmpty ? "session" : safeSessionID).command",
            isDirectory: false
        )
        try resumeScript(sessionID: sessionID, projectPath: projectPath)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        guard NSWorkspace.shared.open(scriptURL) else {
            throw ClaudeCodeSessionLauncherError.openFailed
        }
    }
}
