import Foundation

struct WireMessage<Params: Decodable>: Decodable {
    let method: String
    let params: Params
}

struct RPCErrorPayload: Decodable {
    let code: Int
    let message: String
}

struct ClientInfo: Encodable {
    let name: String
    let version: String
}

struct InitializeParams: Encodable {
    let clientInfo: ClientInfo
    let capabilities: String?
}

struct InitializeResponse: Decodable {
    let userAgent: String
    let codexHome: String?
}

enum ThreadListSortKey: String, Encodable {
    case createdAt = "created_at"
    case updatedAt = "updated_at"
}

struct ThreadListParams: Encodable {
    let cursor: String?
    let limit: Int?
    let sortKey: ThreadListSortKey?
    let archived: Bool?

    init(
        cursor: String? = nil,
        limit: Int? = nil,
        sortKey: ThreadListSortKey? = nil,
        archived: Bool? = nil
    ) {
        self.cursor = cursor
        self.limit = limit
        self.sortKey = sortKey
        self.archived = archived
    }
}

struct ThreadResumeParams: Encodable {
    let threadId: String
    let persistExtendedHistory: Bool
}

struct ThreadUnsubscribeParams: Encodable {
    let threadId: String
}

struct ThreadListResponse: Decodable {
    let data: [CodexThread]
    let nextCursor: String?
}

struct ThreadResumeResponse: Decodable {
    let thread: CodexThread
}

struct ThreadUnsubscribeResponse: Decodable, Equatable {
    let status: String
}

struct CodexThread: Decodable, Equatable {
    let id: String
    let preview: String
    let createdAt: Int
    let updatedAt: Int
    let status: CodexThreadStatus
    let cwd: String
    let name: String?
    let path: String?
    let source: String?
    let agentRole: String?
    let agentNickname: String?

    init(
        id: String,
        preview: String,
        createdAt: Int,
        updatedAt: Int,
        status: CodexThreadStatus,
        cwd: String,
        name: String?,
        path: String? = nil,
        source: String? = nil,
        agentRole: String? = nil,
        agentNickname: String? = nil
    ) {
        self.id = id
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.cwd = cwd
        self.name = name
        self.path = path
        self.source = source
        self.agentRole = agentRole
        self.agentNickname = agentNickname
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case preview
        case createdAt
        case updatedAt
        case status
        case cwd
        case name
        case path
        case source
        case agentRole
        case agentNickname
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        preview = try container.decode(String.self, forKey: .preview)
        updatedAt = try container.decode(Int.self, forKey: .updatedAt)
        createdAt = try container.decodeIfPresent(Int.self, forKey: .createdAt) ?? updatedAt
        status = try container.decode(CodexThreadStatus.self, forKey: .status)
        cwd = try container.decode(String.self, forKey: .cwd)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        if let sourceString = try? container.decode(String.self, forKey: .source) {
            source = sourceString
        } else if let sourcePayload = try? container.decode(ThreadSourcePayload.self, forKey: .source) {
            source = sourcePayload.legacyJSONString
        } else {
            source = nil
        }
        agentRole = try container.decodeIfPresent(String.self, forKey: .agentRole)
        agentNickname = try container.decodeIfPresent(String.self, forKey: .agentNickname)
    }
}

private struct ThreadSourcePayload: Codable {
    let subagent: SubagentPayload?

    private enum CodingKeys: String, CodingKey {
        case subagent
        case subAgent
    }

    init(subagent: SubagentPayload?) {
        self.subagent = subagent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subagent = try container.decodeIfPresent(SubagentPayload.self, forKey: .subagent)
            ?? container.decodeIfPresent(SubagentPayload.self, forKey: .subAgent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(subagent, forKey: .subagent)
    }

    static func parse(from source: String?) -> ThreadSourcePayload? {
        guard let source,
              source.first == "{",
              let data = source.data(using: .utf8)
        else {
            return nil
        }

        return try? JSONDecoder().decode(ThreadSourcePayload.self, from: data)
    }

    var legacyJSONString: String? {
        guard subagent != nil else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

private struct SubagentPayload: Codable {
    let threadSpawn: ThreadSpawnPayload?

    private enum CodingKeys: String, CodingKey {
        case threadSpawn = "thread_spawn"
    }
}

private struct ThreadSpawnPayload: Codable {
    let parentThreadID: String?
    let depth: Int?
    let agentPath: String?
    let agentNickname: String?
    let agentRole: String?

    private enum CodingKeys: String, CodingKey {
        case parentThreadID = "parent_thread_id"
        case depth
        case agentPath = "agent_path"
        case agentNickname = "agent_nickname"
        case agentRole = "agent_role"
    }
}

enum CodexThreadStatus: Decodable, Equatable {
    case notLoaded
    case idle
    case systemError
    case active(flags: [CodexActiveFlag])

    private enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "notLoaded":
            self = .notLoaded
        case "idle":
            self = .idle
        case "systemError":
            self = .systemError
        case "active":
            self = .active(flags: try container.decodeIfPresent([CodexActiveFlag].self, forKey: .activeFlags) ?? [])
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported thread status type: \(type)"
            )
        }
    }
}

enum CodexActiveFlag: String, Decodable, Equatable {
    case waitingOnApproval
    case waitingOnUserInput
}

struct CodexTurn: Decodable, Equatable {
    let id: String
    let status: CodexTurnStatus
    let error: CodexTurnError?
}

enum CodexTurnStatus: String, Decodable, Equatable {
    case completed
    case interrupted
    case failed
    case inProgress

    var displayName: String {
        rawValue
    }
}

struct CodexTurnError: Decodable, Equatable {
    let message: String
}

struct ThreadStartedNotification: Decodable, Equatable {
    let thread: CodexThread
}

struct ThreadStatusChangedNotification: Decodable, Equatable {
    let threadId: String
    let status: CodexThreadStatus
}

struct ThreadArchivedNotification: Decodable, Equatable {
    let threadId: String
}

struct ThreadUnarchivedNotification: Decodable, Equatable {
    let threadId: String
}

struct ThreadNameUpdatedNotification: Decodable, Equatable {
    let threadId: String
    let name: String?

    private enum CodingKeys: String, CodingKey {
        case threadId
        case name
        case thread
    }

    init(threadId: String, name: String?) {
        self.threadId = threadId
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let threadId = try container.decodeIfPresent(String.self, forKey: .threadId) {
            self.threadId = threadId
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
            return
        }

        if let thread = try container.decodeIfPresent(CodexThread.self, forKey: .thread) {
            self.threadId = thread.id
            self.name = thread.name
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .threadId,
            in: container,
            debugDescription: "Unsupported thread/name/updated payload"
        )
    }
}

struct TurnStartedNotification: Decodable, Equatable {
    let threadId: String
    let turn: CodexTurn
}

struct ItemStartedNotification: Decodable, Equatable {
    let threadId: String
    let turnId: String
}

struct TurnCompletedNotification: Decodable, Equatable {
    let threadId: String
    let turn: CodexTurn
}

struct ErrorNotificationPayload: Decodable, Equatable {
    let error: CodexTurnError
    let willRetry: Bool
    let threadId: String
    let turnId: String
}

struct ToolRequestUserInputRequest: Decodable, Equatable {
    let threadId: String
    let turnId: String
    let itemId: String
}

struct ApprovalRequestPayload: Decodable, Equatable {
    let threadId: String
    let turnId: String
    let itemId: String
    let reason: String?
}

struct ServerRequestResolvedNotification: Decodable, Equatable {
    let threadId: String
    let requestId: String?

    init(threadId: String, requestId: String? = nil) {
        self.threadId = threadId
        self.requestId = requestId
    }
}

struct ThreadClosedNotification: Decodable, Equatable {
    let threadId: String
}

extension CodexThread {
    var isSubagent: Bool {
        ThreadSourcePayload.parse(from: source)?.subagent?.threadSpawn != nil
    }

    var subagentParentThreadID: String? {
        guard let parentThreadID = ThreadSourcePayload.parse(from: source)?.subagent?.threadSpawn?.parentThreadID,
              !parentThreadID.isEmpty
        else {
            return nil
        }

        return parentThreadID
    }

    func mergingMetadata(from metadata: CodexThread) -> CodexThread {
        CodexThread(
            id: id,
            preview: preview,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: status,
            cwd: cwd,
            name: name ?? metadata.name,
            path: path ?? metadata.path,
            source: source ?? metadata.source,
            agentRole: agentRole ?? metadata.agentRole,
            agentNickname: agentNickname ?? metadata.agentNickname
        )
    }

    var updatedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAt))
    }

    var displayTitle: String {
        let normalizedName = Self.normalizedDisplayCandidate(name)
        if !normalizedName.isEmpty {
            return Self.truncatedDisplayTitle(normalizedName)
        }

        let normalizedPreview = Self.normalizedDisplayCandidate(preview)
        if normalizedPreview.isEmpty {
            return id
        }

        return Self.truncatedDisplayTitle(normalizedPreview)
    }

    var previewLine: String {
        preview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedDisplayCandidate(_ value: String?) -> String {
        guard let value else { return "" }

        let trimmedLines = value
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = trimmedLines.first else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidate: String
        if firstLine.count < 12, trimmedLines.count > 1 {
            candidate = firstLine + " " + trimmedLines[1]
        } else {
            candidate = firstLine
        }

        return candidate.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
    }

    private static func truncatedDisplayTitle(_ value: String) -> String {
        if value.count > 48 {
            return "\(value.prefix(45))..."
        }

        return value
    }
}
