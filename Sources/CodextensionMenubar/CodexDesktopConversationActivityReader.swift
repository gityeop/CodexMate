import Foundation

final class CodexDesktopConversationActivityReader {
    private struct ParsedLogSnapshot {
        let fileSize: Int
        let modificationDate: Date
        let latestViewedAtByThreadID: [String: Date]
        let latestTurnStartedAtByThreadID: [String: Date]
        let latestTurnCompletedAtByThreadID: [String: Date]
    }

    struct ActivitySnapshot {
        let latestViewedAtByThreadID: [String: Date]
        let latestTurnStartedAtByThreadID: [String: Date]
        let latestTurnCompletedAtByThreadID: [String: Date]
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
        activitySnapshot(now: now).latestViewedAtByThreadID
    }

    func activitySnapshot(now: Date = Date()) -> ActivitySnapshot {
        let logFiles = recentLogFiles(now: now)
        let logFileSet = Set(logFiles)
        parsedLogSnapshotsByURL = parsedLogSnapshotsByURL.filter { logFileSet.contains($0.key) }

        var latestViewedAtByThreadID: [String: Date] = [:]
        var latestTurnStartedAtByThreadID: [String: Date] = [:]
        var latestTurnCompletedAtByThreadID: [String: Date] = [:]

        for logFileURL in logFiles {
            let snapshot = parsedLogSnapshot(for: logFileURL)
            for (threadID, viewedAt) in snapshot.latestViewedAtByThreadID {
                let currentLatest = latestViewedAtByThreadID[threadID] ?? .distantPast
                if viewedAt > currentLatest {
                    latestViewedAtByThreadID[threadID] = viewedAt
                }
            }
            for (threadID, turnStartedAt) in snapshot.latestTurnStartedAtByThreadID {
                let currentLatest = latestTurnStartedAtByThreadID[threadID] ?? .distantPast
                if turnStartedAt > currentLatest {
                    latestTurnStartedAtByThreadID[threadID] = turnStartedAt
                }
            }
            for (threadID, turnCompletedAt) in snapshot.latestTurnCompletedAtByThreadID {
                let currentLatest = latestTurnCompletedAtByThreadID[threadID] ?? .distantPast
                if turnCompletedAt > currentLatest {
                    latestTurnCompletedAtByThreadID[threadID] = turnCompletedAt
                }
            }
        }

        return ActivitySnapshot(
            latestViewedAtByThreadID: latestViewedAtByThreadID,
            latestTurnStartedAtByThreadID: latestTurnStartedAtByThreadID,
            latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
        )
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

        let activitySnapshot = parseLogFile(at: logFileURL)
        let parsedSnapshot = ParsedLogSnapshot(
            fileSize: fileSize,
            modificationDate: modificationDate,
            latestViewedAtByThreadID: activitySnapshot.latestViewedAtByThreadID,
            latestTurnStartedAtByThreadID: activitySnapshot.latestTurnStartedAtByThreadID,
            latestTurnCompletedAtByThreadID: activitySnapshot.latestTurnCompletedAtByThreadID
        )
        parsedLogSnapshotsByURL[logFileURL] = parsedSnapshot
        return parsedSnapshot
    }

    private func parseLogFile(at logFileURL: URL) -> ActivitySnapshot {
        guard let contents = try? String(contentsOf: logFileURL, encoding: .utf8) else {
            return ActivitySnapshot(
                latestViewedAtByThreadID: [:],
                latestTurnStartedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:]
            )
        }

        var latestViewedAtByThreadID: [String: Date] = [:]
        var latestTurnStartedAtByThreadID: [String: Date] = [:]
        var latestTurnCompletedAtByThreadID: [String: Date] = [:]

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let timestampToken = line.split(separator: " ", maxSplits: 1).first,
               let timestamp = parseTimestamp(String(timestampToken)),
               let threadID = tokenValue(for: "conversationId=", in: line),
               threadID != "null" {
                if line.contains("Conversation created") {
                    let currentLatestViewed = latestViewedAtByThreadID[threadID] ?? .distantPast
                    if timestamp > currentLatestViewed {
                        latestViewedAtByThreadID[threadID] = timestamp
                    }
                }

                if line.contains("[desktop-notifications] show turn-complete") ||
                    (line.contains("maybe_resume_success") && line.contains("latestTurnStatus=completed")) {
                    let currentLatestCompleted = latestTurnCompletedAtByThreadID[threadID] ?? .distantPast
                    if timestamp > currentLatestCompleted {
                        latestTurnCompletedAtByThreadID[threadID] = timestamp
                    }
                }
            }

            // Recent Codex desktop builds do not consistently emit thread/resume when a thread is opened,
            // but routed requests with a concrete conversationId still indicate the user is inside that thread.
            guard line.contains("response_routed"),
                  let threadID = tokenValue(for: "conversationId=", in: line),
                  threadID != "null",
                  let method = tokenValue(for: "method=", in: line),
                  let timestampToken = line.split(separator: " ", maxSplits: 1).first,
                  let viewedAt = parseTimestamp(String(timestampToken)) else {
                continue
            }

            let currentLatest = latestViewedAtByThreadID[threadID] ?? .distantPast
            if viewedAt > currentLatest {
                latestViewedAtByThreadID[threadID] = viewedAt
            }

            if method == "turn/start" {
                let currentLatestTurnStart = latestTurnStartedAtByThreadID[threadID] ?? .distantPast
                if viewedAt > currentLatestTurnStart {
                    latestTurnStartedAtByThreadID[threadID] = viewedAt
                }
            }
        }

        return ActivitySnapshot(
            latestViewedAtByThreadID: latestViewedAtByThreadID,
            latestTurnStartedAtByThreadID: latestTurnStartedAtByThreadID,
            latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID
        )
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
