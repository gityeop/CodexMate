import AppKit
import Foundation

enum CodexDeepLink {
    static let threadPathComponent = "threads"

    static func threadURL(threadID: String) -> URL? {
        guard !threadID.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "codex"
        components.host = threadPathComponent
        components.path = "/\(threadID)"
        return components.url
    }
}

enum CodexApplicationLocator {
    private static let bundleIdentifier = "com.openai.codex"

    static func locate() -> URL? {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["CODEX_APP"],
           fileManager.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        if let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspaceURL
        }

        if let bundleURL = bundleURL(fromBinaryURL: try? CodexBinaryLocator.locate()) {
            return bundleURL
        }

        let candidates = [
            "/Applications/Codex.app",
            "\(NSHomeDirectory())/Applications/Codex.app",
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    private static func bundleURL(fromBinaryURL binaryURL: URL?) -> URL? {
        guard let binaryURL else { return nil }

        var currentURL = binaryURL.resolvingSymlinksInPath()
        while currentURL.path != "/" {
            if currentURL.pathExtension == "app" {
                return currentURL
            }

            currentURL.deleteLastPathComponent()
        }

        return nil
    }
}
