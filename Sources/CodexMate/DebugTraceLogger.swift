import Foundation

enum DebugTraceLogger {
    private static let queue = DispatchQueue(label: "CodexMate.DebugTraceLogger")

    static let logFileURL: URL = {
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexMate", isDirectory: true)
        return directoryURL.appendingPathComponent("overlay-debug.log", isDirectory: false)
    }()

    static func log(_ message: String) {
        let compact = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !compact.isEmpty else {
            return
        }

        let line = "[\(String(format: "%.3f", Date().timeIntervalSince1970))] \(compact)\n"

        queue.async {
            let fileManager = FileManager.default
            let directoryURL = logFileURL.deletingLastPathComponent()
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if !fileManager.fileExists(atPath: logFileURL.path) {
                _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: logFileURL),
                  let data = line.data(using: .utf8) else {
                return
            }

            defer {
                try? handle.close()
            }

            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
