import Foundation

struct ThreadDesktopNotification: Equatable {
    enum Kind: Equatable {
        case attention(AppStateStore.ThreadStatus)
        case completion
        case failure(message: String?)
    }

    let threadID: String
    let kind: Kind
}

struct ThreadNotificationMetadata: Equatable {
    let projectDisplayName: String
    let threadTitle: String
    let replySnippet: String?
}

struct ThreadNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String
}

enum ThreadNotificationPlanner {
    static func allowsNotifications(for row: AppStateStore.ThreadRow) -> Bool {
        !row.isSubagent
    }

    static func statusByThreadID(from rows: [AppStateStore.ThreadRow]) -> [String: AppStateStore.ThreadStatus] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.displayStatus) })
    }

    static func notifications(
        previousStatusByThreadID: [String: AppStateStore.ThreadStatus],
        currentRows: [AppStateStore.ThreadRow]
    ) -> [ThreadDesktopNotification] {
        currentRows.compactMap { row in
            guard allowsNotifications(for: row) else { return nil }

            let currentStatus = row.displayStatus
            let previousStatus = previousStatusByThreadID[row.id]

            switch currentStatus {
            case .waitingForInput, .needsApproval:
                guard previousStatus != currentStatus else { return nil }
                return ThreadDesktopNotification(
                    threadID: row.id,
                    kind: .attention(currentStatus)
                )
            case let .failed(message):
                guard previousStatus != currentStatus else { return nil }
                return ThreadDesktopNotification(
                    threadID: row.id,
                    kind: .failure(message: message)
                )
            case .idle:
                guard let previousStatus,
                      previousStatus == .running || previousStatus.isPending else {
                    return nil
                }
                return ThreadDesktopNotification(threadID: row.id, kind: .completion)
            case .notLoaded, .running:
                return nil
            }
        }
    }
}

enum ThreadNotificationContentBuilder {
    private enum Policy {
        static let maxTailBytes = 256 * 1024
        static let maxSnippetCharacters = 180
    }

    static func content(
        body: String,
        metadata: ThreadNotificationMetadata,
        kind: ThreadDesktopNotification.Kind
    ) -> ThreadNotificationContent {
        let subtitle = metadata.threadTitle
        let notificationBody: String

        if case .completion = kind {
            notificationBody = metadata.replySnippet ?? ""
        } else {
            notificationBody = body
        }

        return ThreadNotificationContent(
            title: metadata.projectDisplayName,
            subtitle: subtitle,
            body: notificationBody
        )
    }

    static func latestAssistantReplySnippet(sessionPath: String?) -> String? {
        guard let sessionPath,
              !sessionPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let sessionURL = URL(fileURLWithPath: sessionPath)
        guard let data = tailData(from: sessionURL, maxBytes: Policy.maxTailBytes),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if data.count >= Policy.maxTailBytes, !lines.isEmpty {
            lines.removeFirst()
        }

        for line in lines.reversed() {
            guard let text = assistantMessageText(fromJSONLine: line),
                  let snippet = compactSnippet(text, maxCharacters: Policy.maxSnippetCharacters) else {
                continue
            }

            return snippet
        }

        return nil
    }

    private static func tailData(from url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }

        defer {
            try? handle.close()
        }

        guard let fileSize = try? handle.seekToEnd() else {
            return nil
        }

        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    private static func assistantMessageText(fromJSONLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "assistant" else {
            return nil
        }

        return messageContentText(payload["content"])
    }

    private static func messageContentText(_ content: Any?) -> String? {
        if let text = content as? String {
            return text
        }

        if let contentItems = content as? [[String: Any]] {
            let text = contentItems.compactMap { item -> String? in
                guard let type = item["type"] as? String,
                      type == "output_text" || type == "text" else {
                    return nil
                }

                return item["text"] as? String
            }.joined(separator: " ")

            return text.isEmpty ? nil : text
        }

        return nil
    }

    private static func compactSnippet(_ text: String, maxCharacters: Int) -> String? {
        let compact = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !compact.isEmpty else {
            return nil
        }

        if compact.count <= maxCharacters {
            return compact
        }

        return String(compact.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
