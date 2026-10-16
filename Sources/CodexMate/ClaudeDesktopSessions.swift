import Foundation

/// What Claude Desktop keeps about one of its Code sessions, matched to a transcript by
/// `cliSessionID`. The files are Claude Desktop's own state, so every field is optional.
struct ClaudeDesktopSessionRecord: Equatable, Sendable {
    let cliSessionID: String
    var title: String?
    var cwd: String?
    var isArchived = false
    var lastActivityAt: Date?
    var lastFocusedAt: Date?
}

enum ClaudeDesktopSessionParser {
    static func record(from data: Data) -> ClaudeDesktopSessionRecord? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cliSessionID = nonEmptyString(object["cliSessionId"]) else {
            return nil
        }

        return ClaudeDesktopSessionRecord(
            cliSessionID: cliSessionID,
            title: nonEmptyString(object["title"]).flatMap(ClaudeCodeTranscriptParser.normalizedTitle(_:)),
            cwd: nonEmptyString(object["cwd"]),
            isArchived: (object["isArchived"] as? Bool) == true,
            lastActivityAt: date(fromMilliseconds: object["lastActivityAt"]),
            lastFocusedAt: date(fromMilliseconds: object["lastFocusedAt"])
        )
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let milliseconds = (value as? NSNumber)?.doubleValue, milliseconds > 0 else {
            return nil
        }

        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads `claude-code-sessions/<account>/<org>/local_*.json` and re-parses only files that changed.
struct ClaudeDesktopSessionStore {
    private struct CachedRecord {
        let modifiedAt: Date
        let record: ClaudeDesktopSessionRecord?
    }

    static func defaultDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    private let directoryURL: URL
    private var cache: [String: CachedRecord] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Records keyed by Claude Code transcript id.
    mutating func recordsByCLISessionID() -> [String: ClaudeDesktopSessionRecord] {
        let fileManager = FileManager.default
        var records: [String: ClaudeDesktopSessionRecord] = [:]
        var livePaths: Set<String> = []

        for fileURL in sessionFileURLs(fileManager: fileManager) {
            guard let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else {
                continue
            }

            livePaths.insert(fileURL.path)
            let record: ClaudeDesktopSessionRecord?
            if let cached = cache[fileURL.path], cached.modifiedAt == modifiedAt {
                record = cached.record
            } else {
                record = (try? Data(contentsOf: fileURL)).flatMap(ClaudeDesktopSessionParser.record(from:))
                cache[fileURL.path] = CachedRecord(modifiedAt: modifiedAt, record: record)
            }

            guard let record else {
                continue
            }
            // A transcript can be adopted more than once; keep the most recently active session.
            if let existing = records[record.cliSessionID],
               (existing.lastActivityAt ?? .distantPast) >= (record.lastActivityAt ?? .distantPast) {
                continue
            }
            records[record.cliSessionID] = record
        }

        cache = cache.filter { livePaths.contains($0.key) }
        return records
    }

    private func sessionFileURLs(fileManager: FileManager) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let accountURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: options
        ) else {
            return []
        }

        return accountURLs.flatMap { accountURL -> [URL] in
            let organizationURLs = (try? fileManager.contentsOfDirectory(
                at: accountURL,
                includingPropertiesForKeys: nil,
                options: options
            )) ?? []
            return organizationURLs.flatMap { organizationURL -> [URL] in
                let fileURLs = (try? fileManager.contentsOfDirectory(
                    at: organizationURL,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: options
                )) ?? []
                return fileURLs.filter {
                    $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("local_")
                }
            }
        }
    }
}
