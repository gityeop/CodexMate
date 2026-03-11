import Foundation

final class CodexDesktopConversationActivityReader {
    private struct ParsedLogSnapshot {
        let fileSize: Int
        let modificationDate: Date
        let latestViewedAtByThreadID: [String: Date]
    }

    private let logsDirectoryURL: URL
    private let lookbackDays: Int
    private let fileManager: FileManager
    private var parsedLogSnapshotsByURL: [URL: ParsedLogSnapshot] = [:]

    private let timestampFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    init(
        logsDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library")
            .appending(path: "Logs")
            .appending(path: "com.openai.codex"),
        lookbackDays: Int = 7,
        fileManager: FileManager = .default
    ) {
        self.logsDirectoryURL = logsDirectoryURL
        self.lookbackDays = max(1, lookbackDays)
        self.fileManager = fileManager
    }

    func latestViewedAtByThreadID(now: Date = Date()) -> [String: Date] {
        let logFiles = recentLogFiles(now: now)
        let logFileSet = Set(logFiles)
        parsedLogSnapshotsByURL = parsedLogSnapshotsByURL.filter { logFileSet.contains($0.key) }

        var latestViewedAtByThreadID: [String: Date] = [:]

        for logFileURL in logFiles {
            let snapshot = parsedLogSnapshot(for: logFileURL)
            for (threadID, viewedAt) in snapshot.latestViewedAtByThreadID {
                let currentLatest = latestViewedAtByThreadID[threadID] ?? .distantPast
                if viewedAt > currentLatest {
                    latestViewedAtByThreadID[threadID] = viewedAt
                }
            }
        }

        return latestViewedAtByThreadID
    }

    private func recentLogFiles(now: Date) -> [URL] {
        var logFiles: [URL] = []
        let calendar = Calendar(identifier: .gregorian)

        for dayOffset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }

            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year, let month = components.month, let day = components.day else {
                continue
            }

            let directoryURL = logsDirectoryURL
                .appending(path: String(format: "%04d", year))
                .appending(path: String(format: "%02d", month))
                .appending(path: String(format: "%02d", day))

            guard let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "log" else { continue }
                logFiles.append(fileURL)
            }
        }

        return logFiles.sorted(by: { $0.path < $1.path })
    }

    private func parsedLogSnapshot(for logFileURL: URL) -> ParsedLogSnapshot {
        let resourceValues = (try? logFileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) ?? URLResourceValues()
        let fileSize = resourceValues.fileSize ?? 0
        let modificationDate = resourceValues.contentModificationDate ?? .distantPast

        if let cachedSnapshot = parsedLogSnapshotsByURL[logFileURL],
           cachedSnapshot.fileSize == fileSize,
           cachedSnapshot.modificationDate == modificationDate {
            return cachedSnapshot
        }

        let parsedSnapshot = ParsedLogSnapshot(
            fileSize: fileSize,
            modificationDate: modificationDate,
            latestViewedAtByThreadID: parseLogFile(at: logFileURL)
        )
        parsedLogSnapshotsByURL[logFileURL] = parsedSnapshot
        return parsedSnapshot
    }

    private func parseLogFile(at logFileURL: URL) -> [String: Date] {
        guard let contents = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return [:]
        }

        var latestViewedAtByThreadID: [String: Date] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.contains("method=thread/resume"),
                  let threadID = tokenValue(for: "conversationId=", in: line),
                  threadID != "null",
                  let timestampToken = line.split(separator: " ", maxSplits: 1).first,
                  let viewedAt = parseTimestamp(String(timestampToken)) else {
                continue
            }

            let currentLatest = latestViewedAtByThreadID[threadID] ?? .distantPast
            if viewedAt > currentLatest {
                latestViewedAtByThreadID[threadID] = viewedAt
            }
        }

        return latestViewedAtByThreadID
    }

    private func tokenValue(for prefix: String, in line: String) -> String? {
        guard let range = line.range(of: prefix) else {
            return nil
        }

        let suffix = line[range.upperBound...]
        guard let endIndex = suffix.firstIndex(of: " ") else {
            return String(suffix)
        }

        return String(suffix[..<endIndex])
    }

    private func parseTimestamp(_ value: String) -> Date? {
        timestampFormatterWithFractionalSeconds.date(from: value)
            ?? timestampFormatter.date(from: value)
    }
}
