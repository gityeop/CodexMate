import Foundation

enum DebugTraceLogger {
    private enum Policy {
        static let duplicateSuppressionWindow: TimeInterval = 2
        static let maxTrackedMessages = 256
        static let maxLogFileSizeBytes: UInt64 = 2_000_000
    }

    private struct DuplicateSuppressionState {
        var lastLoggedAtByMessage: [String: Date] = [:]

        mutating func shouldWrite(_ message: String, now: Date) -> Bool {
            prune(now: now)

            if let lastLoggedAt = lastLoggedAtByMessage[message],
               now.timeIntervalSince(lastLoggedAt) < Policy.duplicateSuppressionWindow {
                return false
            }

            lastLoggedAtByMessage[message] = now
            return true
        }

        private mutating func prune(now: Date) {
            let cutoff = now.addingTimeInterval(-Policy.duplicateSuppressionWindow)
            lastLoggedAtByMessage = lastLoggedAtByMessage.filter { $0.value >= cutoff }

            guard lastLoggedAtByMessage.count > Policy.maxTrackedMessages else {
                return
            }

            let sortedEntries = lastLoggedAtByMessage.sorted { $0.value > $1.value }
            lastLoggedAtByMessage = Dictionary(
                uniqueKeysWithValues: sortedEntries
                    .prefix(Policy.maxTrackedMessages)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    private static let queue = DispatchQueue(label: "CodexMate.DebugTraceLogger")
    nonisolated(unsafe) private static var duplicateSuppressionState = DuplicateSuppressionState()

    static let logFileURL: URL = {
        let directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CodexMate", isDirectory: true)
        return directoryURL.appendingPathComponent("overlay-debug.log", isDirectory: false)
    }()

    private static let rotatedLogFileURL: URL = {
        let directoryURL = logFileURL.deletingLastPathComponent()
        return directoryURL.appendingPathComponent("overlay-debug.previous.log", isDirectory: false)
    }()

    static func log(_ message: String) {
        let compact = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !compact.isEmpty else {
            return
        }

        let now = Date()
        let line = "[\(String(format: "%.3f", now.timeIntervalSince1970))] \(compact)\n"

        queue.async {
            guard duplicateSuppressionState.shouldWrite(compact, now: now) else {
                return
            }

            let fileManager = FileManager.default
            let directoryURL = logFileURL.deletingLastPathComponent()
            try? fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            rotateLogFileIfNeeded(fileManager: fileManager)

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

    private static func rotateLogFileIfNeeded(fileManager: FileManager) {
        let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= Policy.maxLogFileSizeBytes else {
            return
        }

        if fileManager.fileExists(atPath: rotatedLogFileURL.path) {
            try? fileManager.removeItem(at: rotatedLogFileURL)
        }
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
        }
    }
}
