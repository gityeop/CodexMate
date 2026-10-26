import Foundation

struct ClaudeCodeSession: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case waitingForUser
        case running
        case idle
    }

    /// What a session in `.waitingForUser` is blocked on.
    enum PendingRequest: Equatable, Sendable {
        case userInput
        case approval
    }

    let id: String
    let title: String?
    let projectPath: String?
    let gitBranch: String?
    let status: Status
    let updatedAt: Date
    var pendingRequest: PendingRequest? = nil
    /// The newest prompt the user sent, shown like a Codex thread preview.
    var preview: String? = nil
    /// When the latest turn ended; nil while a turn is in progress.
    var finishedAt: Date? = nil
    var transcriptPath: String? = nil
    /// When Claude Desktop last brought this session on screen.
    var lastFocusedAt: Date? = nil

    var projectDisplayName: String? {
        guard let projectPath else {
            return nil
        }

        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return name.isEmpty || name == "/" ? projectPath : name
    }

    var isRunning: Bool {
        status == .running
    }

    var isWaitingForUser: Bool {
        status == .waitingForUser
    }

    /// The turn is not over: Claude is working or waiting for the user's answer.
    var isActive: Bool {
        status != .idle
    }
}

/// What the newest transcript entry says about the turn in progress.
enum ClaudeCodeTranscriptPhase: Equatable, Sendable {
    /// A prompt or tool result is waiting for the model, or a requested tool is still running.
    case working
    /// Assistant text without a stop reason, or a slash command; the turn may still continue.
    case likelyWorking
    /// Claude asked the user a question or for plan approval and is blocked on the answer.
    case waitingForUser
    case finished
    case unknown
}

struct ClaudeCodeTranscriptSummary: Equatable, Sendable {
    var projectPath: String?
    var gitBranch: String?
    var customTitle: String?
    var summaryTitle: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var phase: ClaudeCodeTranscriptPhase = .unknown
    /// Timestamp of the entry that decided `phase`.
    var phaseRecordedAt: Date?
    /// Newest user, assistant, or turn-end entry. Unlike the file's modification time, it ignores
    /// the bookkeeping entries Claude Code appends when a session is merely reopened.
    var lastConversationAt: Date?
    var pendingToolName: String?

    var title: String? {
        customTitle ?? summaryTitle ?? firstPrompt
    }
}

enum ClaudeCodeTranscriptParser {
    struct StatusPolicy: Sendable {
        /// A turn with no transcript writes for this long most likely lost its process.
        var workingStaleInterval: TimeInterval = 10 * 60
        var likelyWorkingGraceInterval: TimeInterval = 45
    }

    static let maxTitleLength = 160
    private static let interruptionMarker = "[Request interrupted by user"
    /// Tools whose call stays open until the user answers in Claude Code.
    static let userInputToolNames: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    static func summarize(headLines: [Substring], tailLines: [Substring]) -> ClaudeCodeTranscriptSummary {
        var summary = ClaudeCodeTranscriptSummary()

        for line in headLines {
            let needsContext = summary.projectPath == nil || summary.firstPrompt == nil
            guard needsContext || mayCarryTitle(line) else {
                continue
            }
            guard let record = jsonObject(from: line) else {
                continue
            }

            applyTitle(from: record, to: &summary)
            if summary.projectPath == nil, let cwd = nonEmptyString(record["cwd"]) {
                summary.projectPath = cwd
            }
            if summary.gitBranch == nil, let branch = nonEmptyString(record["gitBranch"]) {
                summary.gitBranch = branch
            }
            if summary.firstPrompt == nil, let prompt = promptText(from: record) {
                summary.firstPrompt = prompt
            }
        }

        var latestContextFound = false
        var tailCustomTitleFound = false
        var tailSummaryTitleFound = false
        for line in tailLines.reversed() {
            let needsContext = !latestContextFound || summary.phase == .unknown || summary.lastConversationAt == nil
            let carriesTitle = mayCarryTitle(line)
            let carriesLastPrompt = summary.lastPrompt == nil && line.contains("\"last-prompt\"")
            guard needsContext || carriesTitle || carriesLastPrompt else {
                continue
            }
            guard let record = jsonObject(from: line) else {
                continue
            }

            if carriesLastPrompt,
               (record["type"] as? String) == "last-prompt",
               let lastPrompt = nonEmptyString(record["lastPrompt"]).flatMap(normalizedTitle(_:)) {
                summary.lastPrompt = lastPrompt
            }

            // Sessions can be renamed or summarized later, so the newest title wins.
            if carriesTitle {
                var tailTitles = ClaudeCodeTranscriptSummary()
                applyTitle(from: record, to: &tailTitles)
                if !tailCustomTitleFound, let customTitle = tailTitles.customTitle {
                    summary.customTitle = customTitle
                    tailCustomTitleFound = true
                }
                if !tailSummaryTitleFound, let summaryTitle = tailTitles.summaryTitle {
                    summary.summaryTitle = summaryTitle
                    tailSummaryTitleFound = true
                }
            }

            if !latestContextFound, let cwd = nonEmptyString(record["cwd"]) {
                latestContextFound = true
                summary.projectPath = cwd
                if let branch = nonEmptyString(record["gitBranch"]) {
                    summary.gitBranch = branch
                }
            }

            if summary.lastConversationAt == nil, isConversationRecord(record) {
                summary.lastConversationAt = timestamp(of: record)
            }

            if summary.phase == .unknown, let latestPhase = Self.phase(of: record) {
                summary.phase = latestPhase
                summary.phaseRecordedAt = timestamp(of: record)
                if latestPhase == .waitingForUser {
                    summary.pendingToolName = userInputToolName(in: record)
                }
            }
        }

        if summary.firstPrompt == nil {
            for line in tailLines {
                guard let record = jsonObject(from: line),
                      let prompt = promptText(from: record) else {
                    continue
                }
                summary.firstPrompt = prompt
                break
            }
        }

        return summary
    }

    static func status(
        for phase: ClaudeCodeTranscriptPhase,
        modifiedAt: Date,
        now: Date,
        policy: StatusPolicy = StatusPolicy()
    ) -> ClaudeCodeSession.Status {
        let age = now.timeIntervalSince(modifiedAt)
        switch phase {
        case .working:
            return age < policy.workingStaleInterval ? .running : .idle
        case .likelyWorking:
            return age < policy.likelyWorkingGraceInterval ? .running : .idle
        case .waitingForUser:
            // A question can wait as long as the user leaves it; the lookback window drops old sessions.
            return .waitingForUser
        case .finished, .unknown:
            return .idle
        }
    }

    /// Returns nil for entries that say nothing about whether the main turn is still going.
    static func phase(of record: [String: Any]) -> ClaudeCodeTranscriptPhase? {
        if (record["isSidechain"] as? Bool) == true {
            return nil
        }

        switch record["type"] as? String {
        case "assistant":
            guard let message = record["message"] as? [String: Any] else {
                return nil
            }

            let blocks = message["content"] as? [[String: Any]] ?? []
            let toolNames = blocks
                .filter { ($0["type"] as? String) == "tool_use" }
                .map { $0["name"] as? String ?? "" }
            if toolNames.contains(where: userInputToolNames.contains) {
                return .waitingForUser
            }
            if !toolNames.isEmpty {
                return .working
            }

            if let stopReason = message["stop_reason"] as? String {
                return stopReason == "tool_use" ? .working : .finished
            }

            return .likelyWorking
        case "user":
            if (record["isMeta"] as? Bool) == true {
                return nil
            }
            guard let message = record["message"] as? [String: Any] else {
                return nil
            }

            if let text = message["content"] as? String {
                return userTextPhase(text)
            }

            let blocks = message["content"] as? [[String: Any]] ?? []
            let texts = blocks.compactMap(blockText(_:))
            if texts.contains(where: { $0.contains(interruptionMarker) }) {
                return .finished
            }
            if blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
                return .working
            }
            if let text = texts.first {
                return userTextPhase(text)
            }

            // Image-only prompts still start a turn.
            return blocks.isEmpty ? nil : .working
        case "system":
            switch record["subtype"] as? String {
            // Newer Claude Code records slash commands and their output as `local_command`;
            // they run without a model turn and cannot start while one is in progress.
            case "turn_duration", "stop_hook_summary", "local_command":
                return .finished
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func promptText(from record: [String: Any]) -> String? {
        guard (record["type"] as? String) == "user",
              (record["isMeta"] as? Bool) != true,
              (record["isSidechain"] as? Bool) != true,
              let message = record["message"] as? [String: Any] else {
            return nil
        }

        let rawText: String?
        if let text = message["content"] as? String {
            rawText = text
        } else if let blocks = message["content"] as? [[String: Any]],
                  !blocks.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            rawText = blocks.compactMap(blockText(_:)).first
        } else {
            rawText = nil
        }

        guard let rawText else {
            return nil
        }

        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("Caveat:"),
              !trimmed.contains(interruptionMarker) else {
            return nil
        }

        return normalizedTitle(trimmed)
    }

    static func normalizedTitle(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else {
            return nil
        }

        guard collapsed.count > maxTitleLength else {
            return collapsed
        }

        return String(collapsed.prefix(maxTitleLength - 1)) + "…"
    }

    private static func userTextPhase(_ text: String) -> ClaudeCodeTranscriptPhase {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(interruptionMarker)
            || trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<local-command-stderr>") {
            return .finished
        }

        if trimmed.hasPrefix("<command-name>") || trimmed.hasPrefix("<command-message>") {
            return .likelyWorking
        }

        return .working
    }

    private static func applyTitle(from record: [String: Any], to summary: inout ClaudeCodeTranscriptSummary) {
        switch record["type"] as? String {
        case "custom-title":
            let title = nonEmptyString(record["customTitle"]) ?? nonEmptyString(record["title"])
            if let title = title.flatMap(normalizedTitle(_:)) {
                summary.customTitle = title
            }
        case "summary":
            if let title = nonEmptyString(record["summary"]).flatMap(normalizedTitle(_:)) {
                summary.summaryTitle = title
            }
        default:
            break
        }
    }

    private static func isConversationRecord(_ record: [String: Any]) -> Bool {
        guard (record["isSidechain"] as? Bool) != true, record["timestamp"] is String else {
            return false
        }

        switch record["type"] as? String {
        case "user", "assistant":
            return true
        case "system":
            return ["turn_duration", "stop_hook_summary", "local_command"].contains(record["subtype"] as? String ?? "")
        default:
            return false
        }
    }

    private static func userInputToolName(in record: [String: Any]) -> String? {
        let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks
            .compactMap { $0["name"] as? String }
            .first(where: userInputToolNames.contains)
    }

    private static func timestamp(of record: [String: Any]) -> Date? {
        guard let text = record["timestamp"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func mayCarryTitle(_ line: Substring) -> Bool {
        line.contains("\"custom-title\"") || line.contains("\"summary\"")
    }

    private static func blockText(_ block: [String: Any]) -> String? {
        guard (block["type"] as? String) == "text" else {
            return nil
        }

        return block["text"] as? String
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonObject(from line: Substring) -> [String: Any]? {
        guard line.first == "{" else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// Lists recent Claude Code sessions from the transcripts Claude Code writes under
/// `~/.claude/projects/<project>/<session-id>.jsonl`.
actor ClaudeCodeSessionService {
    struct Configuration: Sendable {
        // Wide enough to fill the Recent list next to Codex threads.
        var lookbackInterval: TimeInterval = 7 * 24 * 60 * 60
        var maxSessions = 40
        var headByteCount = 256 * 1024
        var tailByteCounts = [128 * 1024, 2 * 1024 * 1024]
        var statusPolicy = ClaudeCodeTranscriptParser.StatusPolicy()
    }

    private struct TranscriptFile {
        let url: URL
        let sessionID: String
        let modifiedAt: Date
        let size: Int
    }

    private struct CachedTranscript {
        let modifiedAt: Date
        let size: Int
        let summary: ClaudeCodeTranscriptSummary
    }

    private let projectsDirectoryURLProvider: @Sendable () -> URL
    private let configuration: Configuration
    private var cache: [String: CachedTranscript] = [:]
    private var desktopSessionStore: ClaudeDesktopSessionStore

    init(
        projectsDirectoryURLProvider: @escaping @Sendable () -> URL = { ClaudeCodePaths.projectsDirectoryURL() },
        desktopSessionsDirectoryURL: URL = ClaudeDesktopSessionStore.defaultDirectoryURL(),
        configuration: Configuration = Configuration()
    ) {
        self.projectsDirectoryURLProvider = projectsDirectoryURLProvider
        self.desktopSessionStore = ClaudeDesktopSessionStore(directoryURL: desktopSessionsDirectoryURL)
        self.configuration = configuration
    }

    func recentSessions(now: Date = Date()) -> [ClaudeCodeSession] {
        let files = recentTranscriptFiles(now: now)
        let desktopRecords = desktopSessionStore.recordsByCLISessionID()
        var sessions: [ClaudeCodeSession] = []
        var livePaths: Set<String> = []

        for file in files {
            livePaths.insert(file.url.path)
            let desktopRecord = desktopRecords[file.sessionID]
            // Archived Desktop sessions leave the list, like archived Codex threads.
            if desktopRecord?.isArchived == true {
                continue
            }

            let summary = transcriptSummary(for: file)
            sessions.append(
                Self.session(
                    sessionID: file.sessionID,
                    transcriptPath: file.url.path,
                    modifiedAt: file.modifiedAt,
                    summary: summary,
                    desktopRecord: desktopRecord,
                    now: now,
                    policy: configuration.statusPolicy
                )
            )
        }

        cache = cache.filter { livePaths.contains($0.key) }

        return Array(
            sessions
                .sorted { lhs, rhs in
                    if lhs.isWaitingForUser != rhs.isWaitingForUser {
                        return lhs.isWaitingForUser
                    }
                    if lhs.isActive != rhs.isActive {
                        return lhs.isActive
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
                .prefix(configuration.maxSessions)
        )
    }

    static func session(
        sessionID: String,
        transcriptPath: String?,
        modifiedAt: Date,
        summary: ClaudeCodeTranscriptSummary,
        desktopRecord: ClaudeDesktopSessionRecord?,
        now: Date,
        policy: ClaudeCodeTranscriptParser.StatusPolicy = ClaudeCodeTranscriptParser.StatusPolicy()
    ) -> ClaudeCodeSession {
        let status = ClaudeCodeTranscriptParser.status(
            for: summary.phase,
            modifiedAt: modifiedAt,
            now: now,
            policy: policy
        )
        let pendingRequest: ClaudeCodeSession.PendingRequest?
        if status == .waitingForUser {
            pendingRequest = summary.pendingToolName == "ExitPlanMode" ? .approval : .userInput
        } else {
            pendingRequest = nil
        }

        let finishedAt: Date?
        switch (status, summary.phase) {
        case (.idle, .finished):
            finishedAt = summary.phaseRecordedAt ?? modifiedAt
        case (.idle, _):
            // The turn went stale without an end marker; its last message is the best end time.
            finishedAt = summary.lastConversationAt ?? modifiedAt
        default:
            finishedAt = nil
        }

        return ClaudeCodeSession(
            id: sessionID,
            // Desktop keeps the user's renames, and forks copy the parent's transcript title.
            title: desktopRecord?.title ?? summary.title,
            projectPath: summary.projectPath ?? desktopRecord?.cwd,
            gitBranch: summary.gitBranch,
            status: status,
            updatedAt: activityDate(summary: summary, desktopRecord: desktopRecord, modifiedAt: modifiedAt),
            pendingRequest: pendingRequest,
            preview: summary.lastPrompt ?? summary.firstPrompt,
            finishedAt: finishedAt,
            transcriptPath: transcriptPath,
            lastFocusedAt: desktopRecord?.lastFocusedAt
        )
    }

    /// When the conversation last moved. Reopening a session appends bookkeeping entries and
    /// touches the file, so the modification time is only a fallback.
    static func activityDate(
        summary: ClaudeCodeTranscriptSummary,
        desktopRecord: ClaudeDesktopSessionRecord?,
        modifiedAt: Date
    ) -> Date {
        [summary.lastConversationAt, desktopRecord?.lastActivityAt].compactMap { $0 }.max() ?? modifiedAt
    }

    private func recentTranscriptFiles(now: Date) -> [TranscriptFile] {
        let fileManager = FileManager.default
        let projectsDirectoryURL = projectsDirectoryURLProvider()
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let projectDirectories = try? fileManager.contentsOfDirectory(
            at: projectsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let oldestAllowed = now.addingTimeInterval(-configuration.lookbackInterval)
        var filesBySessionID: [String: TranscriptFile] = [:]
        for directoryURL in projectDirectories {
            guard (try? directoryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let entries = try? fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for entryURL in entries where entryURL.pathExtension == "jsonl" {
                let sessionID = entryURL.deletingPathExtension().lastPathComponent
                // Older Claude Code versions keep subagent transcripts beside the session.
                guard !sessionID.hasPrefix("agent-"),
                      let values = try? entryURL.resourceValues(forKeys: Set(resourceKeys)),
                      values.isDirectory != true,
                      let modifiedAt = values.contentModificationDate,
                      modifiedAt >= oldestAllowed else {
                    continue
                }

                // Resumed sessions can exist in both a project and its worktree.
                // Select the latest copy before parsing status or limiting the list.
                if let existing = filesBySessionID[sessionID],
                   existing.modifiedAt > modifiedAt
                    || (existing.modifiedAt == modifiedAt && existing.url.path < entryURL.path) {
                    continue
                }
                filesBySessionID[sessionID] = TranscriptFile(
                    url: entryURL,
                    sessionID: sessionID,
                    modifiedAt: modifiedAt,
                    size: values.fileSize ?? 0
                )
            }
        }

        return Array(filesBySessionID.values)
    }

    private func transcriptSummary(for file: TranscriptFile) -> ClaudeCodeTranscriptSummary {
        if let cached = cache[file.url.path],
           cached.modifiedAt == file.modifiedAt,
           cached.size == file.size {
            return cached.summary
        }

        let summary = readSummary(of: file)
        cache[file.url.path] = CachedTranscript(
            modifiedAt: file.modifiedAt,
            size: file.size,
            summary: summary
        )
        return summary
    }

    private func readSummary(of file: TranscriptFile) -> ClaudeCodeTranscriptSummary {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            return ClaudeCodeTranscriptSummary()
        }
        defer {
            try? handle.close()
        }

        let headLines = readLines(
            from: handle,
            offset: 0,
            length: configuration.headByteCount,
            fileSize: file.size
        )

        var summary = ClaudeCodeTranscriptSummary()
        for tailByteCount in configuration.tailByteCounts {
            let offset = max(0, file.size - tailByteCount)
            let tailLines = readLines(
                from: handle,
                offset: offset,
                length: file.size - offset,
                fileSize: file.size
            )
            summary = ClaudeCodeTranscriptParser.summarize(headLines: headLines, tailLines: tailLines)
            // A single huge tool result can fill the whole window; retry with a larger one.
            if summary.phase != .unknown || offset == 0 {
                break
            }
        }

        return summary
    }

    private func readLines(
        from handle: FileHandle,
        offset: Int,
        length: Int,
        fileSize: Int
    ) -> [Substring] {
        guard length > 0 else {
            return []
        }

        do {
            try handle.seek(toOffset: UInt64(offset))
        } catch {
            return []
        }

        let data = handle.readData(ofLength: length)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        // Drop lines cut by the read window.
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        if offset + data.count < fileSize, !lines.isEmpty, text.last != "\n" {
            lines.removeLast()
        }

        return lines
    }
}
