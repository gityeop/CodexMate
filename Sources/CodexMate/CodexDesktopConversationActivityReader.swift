import Foundation

final class CodexDesktopConversationActivityReader {
    private struct ParsedLogSnapshot {
        let fileSize: UInt64
        let modificationDate: Date
        let latestViewedAtByThreadID: [String: Date]
        let latestTurnStartedAtByThreadID: [String: Date]
        let latestTurnCompletedAtByThreadID: [String: Date]
        let trailingFragment: String
    }

    struct ActivitySnapshot {
        let latestViewedAtByThreadID: [String: Date]
        let latestTurnStartedAtByThreadID: [String: Date]
        let latestTurnCompletedAtByThreadID: [String: Date]
    }

    private let logsDirectoryURL: URL
    private let lookbackDays: Int
    private let fileManager: FileManager
    private let recentLogFileCacheLifetime: TimeInterval
    private var parsedLogSnapshotsByURL: [URL: ParsedLogSnapshot] = [:]
    private var cachedRecentLogFiles: (key: String, checkedAt: Date, files: [URL])?

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
        recentLogFileCacheLifetime: TimeInterval = 5,
        fileManager: FileManager = .default
    ) {
        self.logsDirectoryURL = logsDirectoryURL
        self.lookbackDays = max(1, lookbackDays)
        self.recentLogFileCacheLifetime = max(1, recentLogFileCacheLifetime)
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
        let cacheKey = recentLogFileCacheKey(now: now)
        if let cachedRecentLogFiles,
           cachedRecentLogFiles.key == cacheKey,
           now.timeIntervalSince(cachedRecentLogFiles.checkedAt) < recentLogFileCacheLifetime {
            return cachedRecentLogFiles.files
        }

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

        let sortedLogFiles = logFiles.sorted(by: { $0.path < $1.path })
        cachedRecentLogFiles = (key: cacheKey, checkedAt: now, files: sortedLogFiles)
        return sortedLogFiles
    }

    private func recentLogFileCacheKey(now: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)

        return (0..<lookbackDays)
            .compactMap { dayOffset in
                calendar.date(byAdding: .day, value: -dayOffset, to: now)
            }
            .compactMap { day in
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                guard let year = components.year,
                      let month = components.month,
                      let day = components.day
                else {
                    return nil
                }

                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            .joined(separator: "|")
    }

    private func parsedLogSnapshot(for logFileURL: URL) -> ParsedLogSnapshot {
        let resourceValues = (try? logFileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])) ?? URLResourceValues()
        let fileSize = currentFileSize(for: logFileURL) ?? UInt64(max(0, resourceValues.fileSize ?? 0))
        let modificationDate = resourceValues.contentModificationDate ?? .distantPast

        if let cachedSnapshot = parsedLogSnapshotsByURL[logFileURL],
           cachedSnapshot.fileSize == fileSize,
           cachedSnapshot.modificationDate == modificationDate {
            return cachedSnapshot
        }

        let activitySnapshot: ParsedLogSnapshot
        if let cachedSnapshot = parsedLogSnapshotsByURL[logFileURL],
           cachedSnapshot.trailingFragment.isEmpty,
           fileSize >= cachedSnapshot.fileSize,
           modificationDate >= cachedSnapshot.modificationDate {
            let deltaSnapshot = parseLogFile(
                at: logFileURL,
                startingAt: cachedSnapshot.fileSize,
                carryover: cachedSnapshot.trailingFragment
            )
            activitySnapshot = ParsedLogSnapshot(
                fileSize: fileSize,
                modificationDate: modificationDate,
                latestViewedAtByThreadID: mergeLatestDates(
                    existing: cachedSnapshot.latestViewedAtByThreadID,
                    updates: deltaSnapshot.latestViewedAtByThreadID
                ),
                latestTurnStartedAtByThreadID: mergeLatestDates(
                    existing: cachedSnapshot.latestTurnStartedAtByThreadID,
                    updates: deltaSnapshot.latestTurnStartedAtByThreadID
                ),
                latestTurnCompletedAtByThreadID: mergeLatestDates(
                    existing: cachedSnapshot.latestTurnCompletedAtByThreadID,
                    updates: deltaSnapshot.latestTurnCompletedAtByThreadID
                ),
                trailingFragment: deltaSnapshot.trailingFragment
            )
        } else {
            let fullSnapshot = parseLogFile(at: logFileURL)
            activitySnapshot = ParsedLogSnapshot(
                fileSize: fileSize,
                modificationDate: modificationDate,
                latestViewedAtByThreadID: fullSnapshot.latestViewedAtByThreadID,
                latestTurnStartedAtByThreadID: fullSnapshot.latestTurnStartedAtByThreadID,
                latestTurnCompletedAtByThreadID: fullSnapshot.latestTurnCompletedAtByThreadID,
                trailingFragment: fullSnapshot.trailingFragment
            )
        }

        parsedLogSnapshotsByURL[logFileURL] = activitySnapshot
        return activitySnapshot
    }

    private func currentFileSize(for logFileURL: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else {
            return nil
        }
        defer { handle.closeFile() }

        return handle.seekToEndOfFile()
    }

    private func mergeLatestDates(
        existing: [String: Date],
        updates: [String: Date]
    ) -> [String: Date] {
        var merged = existing
        for (threadID, date) in updates {
            if date > (merged[threadID] ?? .distantPast) {
                merged[threadID] = date
            }
        }

        return merged
    }

    private func parseLogFile(
        at logFileURL: URL,
        startingAt offset: UInt64 = 0,
        carryover: String = ""
    ) -> ParsedLogSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else {
            return ParsedLogSnapshot(
                fileSize: offset,
                modificationDate: .distantPast,
                latestViewedAtByThreadID: [:],
                latestTurnStartedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:],
                trailingFragment: carryover
            )
        }
        defer { handle.closeFile() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ParsedLogSnapshot(
                fileSize: offset,
                modificationDate: .distantPast,
                latestViewedAtByThreadID: [:],
                latestTurnStartedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:],
                trailingFragment: carryover
            )
        }

        let data = handle.readDataToEndOfFile()
        let contents = carryover + String(decoding: data, as: UTF8.self)
        let parsed = parseLogContents(contents)

        let parsedSnapshot = ParsedLogSnapshot(
            fileSize: offset + UInt64(data.count),
            modificationDate: .distantPast,
            latestViewedAtByThreadID: parsed.latestViewedAtByThreadID,
            latestTurnStartedAtByThreadID: parsed.latestTurnStartedAtByThreadID,
            latestTurnCompletedAtByThreadID: parsed.latestTurnCompletedAtByThreadID,
            trailingFragment: parsed.trailingFragment
        )
        return parsedSnapshot
    }

    private func parseLogContents(_ contents: String) -> ParsedLogSnapshot {
        guard !contents.isEmpty else {
            return ParsedLogSnapshot(
                fileSize: 0,
                modificationDate: .distantPast,
                latestViewedAtByThreadID: [:],
                latestTurnStartedAtByThreadID: [:],
                latestTurnCompletedAtByThreadID: [:],
                trailingFragment: ""
            )
        }

        var lines = contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map(String.init)
        let trailingFragment: String
        if let lastCharacter = contents.last,
           !lastCharacter.isNewline,
           let lastLine = lines.last,
           isLikelyIncompleteLogLine(lastLine) {
            trailingFragment = lines.removeLast()
        } else {
            trailingFragment = ""
        }

        var latestViewedAtByThreadID: [String: Date] = [:]
        var latestTurnStartedAtByThreadID: [String: Date] = [:]
        var latestTurnCompletedAtByThreadID: [String: Date] = [:]

        for line in lines where !line.isEmpty {
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

                // `maybe_resume_success` is emitted when reopening an already-completed thread,
                // so only the explicit completion notification should advance terminal activity.
                if line.contains("[desktop-notifications] show turn-complete") {
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

        return ParsedLogSnapshot(
            fileSize: 0,
            modificationDate: .distantPast,
            latestViewedAtByThreadID: latestViewedAtByThreadID,
            latestTurnStartedAtByThreadID: latestTurnStartedAtByThreadID,
            latestTurnCompletedAtByThreadID: latestTurnCompletedAtByThreadID,
            trailingFragment: trailingFragment
        )
    }

    private func isLikelyIncompleteLogLine(_ line: String) -> Bool {
        if line.contains("response_routed") {
            return tokenValue(for: "conversationId=", in: line) == nil
                || tokenValue(for: "method=", in: line) == nil
        }

        if line.contains("Conversation created")
            || line.contains("maybe_resume_success")
            || line.contains("[desktop-notifications] show turn-complete") {
            return tokenValue(for: "conversationId=", in: line) == nil
        }

        return false
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
