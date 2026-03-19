import Foundation

struct MenubarStatusPresentation {
    private static let truncationMarker = "…"

    enum ThreadIndicator: Equatable {
        case unread
        case running
        case waitingForUser
        case failed
    }

    struct ThreadTooltipContent: Equatable {
        struct Detail: Equatable {
            enum Kind: Equatable {
                case approval
                case error
            }

            let kind: Kind
            let text: String
        }

        let headerTitle: String?
        let worktreeDisplayName: String?
        let worktreeLine: String?
        let title: String?
        let details: [Detail]
        let preview: String?

        var lines: [String] {
            var lines: [String] = []

            if let worktreeLine {
                lines.append(worktreeLine)
            }

            if let title {
                lines.append(title)
            }

            lines.append(contentsOf: details.map(\.text))

            if let preview {
                lines.append(preview)
            }

            return lines
        }
    }

    static func statusItemIcon(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) -> String {
        if hasUnreadThreads && overallStatus != .connecting && overallStatus != .running && overallStatus != .waitingForUser {
            return "🔵"
        }

        return overallStatus.icon
    }

    static func statusDisplayName(
        overallStatus: AppStateStore.OverallStatus,
        hasUnreadThreads: Bool,
        strings: AppStrings = .shared,
        language: AppLanguage = .english
    ) -> String {
        if hasUnreadThreads && overallStatus != .connecting && overallStatus != .running && overallStatus != .waitingForUser {
            return strings.text("status.unread", language: language)
        }

        return overallStatus.displayName
    }

    static func threadTitle(
        for thread: AppStateStore.ThreadRow,
        relativeDate: String,
        maxDisplayTitleLength: Int? = nil
    ) -> String {
        "\(truncated(thread.displayTitle, maxLength: maxDisplayTitleLength)) | \(relativeDate)"
    }

    static func projectSectionTitle(
        displayName: String,
        threadCount: Int,
        maxDisplayNameLength: Int? = nil,
        strings: AppStrings = .shared,
        language: AppLanguage = .english
    ) -> String {
        let key = threadCount == 1 ? "menu.projectSection.one" : "menu.projectSection.other"
        return strings.format(
            key,
            language: language,
            truncated(displayName, maxLength: maxDisplayNameLength),
            Int64(threadCount)
        )
    }

    static func threadTooltipContent(
        worktreeDisplayName: String,
        thread: AppStateStore.ThreadRow,
        strings: AppStrings = .shared,
        language: AppLanguage = .english
    ) -> ThreadTooltipContent {
        let title = normalizedLine(thread.displayTitle)
        let preview = normalizedLine(thread.preview)
        var details: [ThreadTooltipContent.Detail] = []

        if thread.pendingRequestKind == .approval,
           let reason = normalizedLine(thread.pendingRequestReason) {
            details.append(
                ThreadTooltipContent.Detail(
                    kind: .approval,
                    text: strings.format("tooltip.detail.approval", language: language, reason)
                )
            )
        }

        if case let .failed(message?) = thread.displayStatus,
           let message = normalizedLine(message) {
            details.append(
                ThreadTooltipContent.Detail(
                    kind: .error,
                    text: strings.format("tooltip.detail.error", language: language, message)
                )
            )
        }

        return ThreadTooltipContent(
            headerTitle: strings.text("tooltip.worktreeHeader", language: language),
            worktreeDisplayName: normalizedLine(worktreeDisplayName),
            worktreeLine: strings.format("tooltip.worktreeLine", language: language, worktreeDisplayName),
            title: title,
            details: details,
            preview: preview == title ? nil : preview
        )
    }

    static func threadTooltip(
        worktreeDisplayName: String,
        thread: AppStateStore.ThreadRow,
        strings: AppStrings = .shared,
        language: AppLanguage = .english
    ) -> String {
        threadTooltipContent(
            worktreeDisplayName: worktreeDisplayName,
            thread: thread,
            strings: strings,
            language: language
        )
            .lines
            .joined(separator: "\n")
    }

    static func threadIndicator(for thread: AppStateStore.ThreadRow, hasUnreadContent: Bool) -> ThreadIndicator? {
        switch thread.presentationStatus {
        case .running:
            return .running
        case .waitingForUser:
            return .waitingForUser
        case .failed:
            return .failed
        case .idle, .notLoaded:
            return hasUnreadContent ? .unread : nil
        }
    }

    private static func truncated(_ text: String, maxLength: Int?) -> String {
        guard let maxLength, maxLength > 0, text.count > maxLength else {
            return text
        }

        if maxLength == 1 {
            return truncationMarker
        }

        return String(text.prefix(maxLength - 1)) + truncationMarker
    }

    private static func normalizedLine(_ text: String?) -> String? {
        guard let text else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
