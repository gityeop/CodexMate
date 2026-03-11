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
}

struct ThreadListParams: Encodable {
    let limit: Int?
    let archived: Bool?
}

struct ThreadResumeParams: Encodable {
    let threadId: String
    let persistExtendedHistory: Bool
}

struct ThreadListResponse: Decodable {
    let data: [CodexThread]
    let nextCursor: String?
}

struct ThreadResumeResponse: Decodable {
    let thread: CodexThread
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

    init(
        id: String,
        preview: String,
        createdAt: Int,
        updatedAt: Int,
        status: CodexThreadStatus,
        cwd: String,
        name: String?,
        path: String? = nil
    ) {
        self.id = id
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.cwd = cwd
        self.name = name
        self.path = path
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

struct TurnStartedNotification: Decodable, Equatable {
    let threadId: String
    let turn: CodexTurn
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
}

extension CodexThread {
    var updatedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(updatedAt))
    }

    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        let trimmed = previewLine
        if trimmed.isEmpty {
            return id
        }

        if trimmed.count > 48 {
            let prefix = trimmed.prefix(45)
            return "\(prefix)..."
        }

        return trimmed
    }

    var previewLine: String {
        preview
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
