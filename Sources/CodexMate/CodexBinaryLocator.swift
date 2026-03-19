import Foundation

enum CodexBinaryLocator {
    static func locate() throws -> URL {
        let fileManager = FileManager.default

        let environmentOverride = ProcessInfo.processInfo.environment["CODEX_BINARY"]
        if let environmentOverride, fileManager.isExecutableFile(atPath: environmentOverride) {
            return URL(fileURLWithPath: environmentOverride)
        }

        for candidate in candidatePaths() where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        throw NSError(
            domain: "CodexMate.CodexBinaryLocator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate a usable codex binary. Set CODEX_BINARY or install Codex.app."]
        )
    }

    private static func candidatePaths() -> [String] {
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        let pathCandidates = pathEntries.map { "\($0)/codex" }

        return [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/MacOS/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/Resources/codex",
            "\(NSHomeDirectory())/Applications/Codex.app/Contents/MacOS/codex",
        ] + pathCandidates
    }
}
