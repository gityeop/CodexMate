import Foundation

struct AppStateStore {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(binaryPath: String)
        case failed(message: String)
    }

    enum OverallStatus: Equatable {
        case connecting
        case idle
        case waitingForInput
        case running
        case needsApproval
        case failed

        var icon: String {
            switch self {
            case .connecting:
                return "⏳"
            case .idle:
                return "✅"
            case .waitingForInput:
                return "💬"
            case .running:
                return "⏳"
            case .needsApproval:
                return "🟡"
            case .failed:
                return "⚠️"
            }
        }

        var displayName: String {
            switch self {
            case .connecting:
                return "Connecting"
            case .idle:
                return "Idle"
            case .waitingForInput:
                return "Waiting for input"
            case .running:
                return "Running"
            case .needsApproval:
                return "Needs approval"
            case .failed:
                return "Failed"
            }
        }
    }

    enum ThreadStatus: Equatable {
        case notLoaded
        case idle
        case waitingForInput
        case running
        case needsApproval
        case failed(message: String?)

        var displayName: String {
            switch self {
            case .notLoaded:
                return "Not loaded"
            case .idle:
                return "Idle"
            case .waitingForInput:
                return "Waiting for input"
            case .running:
                return "Running"
            case .needsApproval:
                return "Needs approval"
            case .failed:
                return "Failed"
            }
        }

        var isPending: Bool {
            switch self {
            case .waitingForInput, .needsApproval:
                return true
            case .notLoaded, .idle, .running, .failed:
                return false
            }
        }
    }

    struct ThreadRow: Equatable, Identifiable {
        let id: String
        var displayTitle: String
        var preview: String
        var cwd: String
        var status: ThreadStatus
        var updatedAt: Date
        var isWatched: Bool
        var activeTurnID: String?
    }

    enum NotificationEvent {
        case threadStarted(ThreadStartedNotification)
        case threadStatusChanged(ThreadStatusChangedNotification)
        case turnStarted(TurnStartedNotification)
        case turnCompleted(TurnCompletedNotification)
        case error(ErrorNotificationPayload)
    }

    enum ServerRequestEvent {
        case toolUserInput(ToolRequestUserInputRequest)
        case approval(ApprovalRequestPayload)
    }

    private(set) var connection: ConnectionState = .disconnected
    private(set) var threadsByID: [String: ThreadRow] = [:]
    private(set) var lastDiagnostic: String?
    private(set) var desktopActiveTurnCount: Int = 0
    private(set) var desktopDebugSummary: String?

    var recentThreads: [ThreadRow] {
        threadsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var overallStatus: OverallStatus {
        switch connection {
        case .connecting:
            return .connecting
        case .failed:
            return .failed
        case .disconnected, .connected:
            break
        }

        let threads = recentThreads

        if threads.contains(where: {
            if case .waitingForInput = $0.status { return true }
            return false
        }) {
            return .waitingForInput
        }

        if threads.contains(where: {
            if case .needsApproval = $0.status { return true }
            return false
        }) {
            return .needsApproval
        }

        if threads.contains(where: {
            if case .running = $0.status { return true }
            return false
        }) {
            return .running
        }

        if desktopActiveTurnCount > 0 {
            return .running
        }

        let watchedThreads = threads.filter(\.isWatched)

        if watchedThreads.contains(where: {
            if case .failed = $0.status { return true }
            return false
        }) {
            return .failed
        }

        return .idle
    }

    var connectionDescription: String {
        switch connection {
        case .disconnected:
            return "Not connected"
        case .connecting:
            return "Connecting to Codex app-server"
        case let .connected(binaryPath):
            return "Connected: \(binaryPath)"
        case let .failed(message):
            return "Error: \(message)"
        }
    }

    var summaryText: String {
        let watchedCount = recentThreads.filter(\.isWatched).count
        let runningThreadCount = recentThreads.filter {
            if case .running = $0.status { return true }
            return false
        }.count
        let runningCount = max(runningThreadCount, desktopActiveTurnCount)
        let waitingCount = recentThreads.filter {
            if case .waitingForInput = $0.status { return true }
            return false
        }.count
        let approvalCount = recentThreads.filter {
            if case .needsApproval = $0.status { return true }
            return false
        }.count

        return "Recent \(recentThreads.count) | Watching \(watchedCount) | Running \(runningCount) | Reply \(waitingCount) | Approval \(approvalCount)"
    }

    var debugStatusSnapshot: String {
        let waitingThreadIDs = recentThreads.compactMap { thread in
            if case .waitingForInput = thread.status { return shortThreadID(thread.id) }
            return nil
        }
        let approvalThreadIDs = recentThreads.compactMap { thread in
            if case .needsApproval = thread.status { return shortThreadID(thread.id) }
            return nil
        }
        let runningThreadIDs = recentThreads.compactMap { thread in
            if case .running = thread.status { return shortThreadID(thread.id) }
            return nil
        }

        return "waiting=\(debugList(waitingThreadIDs)) approval=\(debugList(approvalThreadIDs)) running=\(debugList(runningThreadIDs)) turns=\(desktopActiveTurnCount)"
    }

    mutating func setConnection(_ connection: ConnectionState) {
        self.connection = connection
    }

    mutating func recordDiagnostic(_ diagnostic: String) {
        let compact = diagnostic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !compact.isEmpty else { return }
        lastDiagnostic = compact
    }

    mutating func replaceRecentThreads(with threads: [CodexThread]) {
        var updatedThreads: [String: ThreadRow] = [:]

        for thread in threads {
            var row = threadsByID[thread.id] ?? ThreadRow(thread: thread, isWatched: false)
            row.displayTitle = thread.displayTitle
            row.preview = thread.previewLine
            row.cwd = thread.cwd
            row.updatedAt = thread.updatedDate

            let newStatus = ThreadStatus(threadStatus: thread.status)
            if let preservedStatus = preservedStatus(current: row.status, incoming: newStatus, isWatched: row.isWatched) {
                if row.status.isPending && (newStatus == .idle || newStatus == .notLoaded) {
                    recordDiagnostic("preserved pending thread=\(shortThreadID(thread.id)) kept=\(row.status.displayName) incoming=\(newStatus.displayName)")
                }
                row.status = preservedStatus
            } else {
                row.status = newStatus
            }

            updatedThreads[thread.id] = row
        }

        for (threadID, row) in threadsByID where row.isWatched && updatedThreads[threadID] == nil {
            updatedThreads[threadID] = row
        }

        threadsByID = updatedThreads
    }

    mutating func markWatched(thread: CodexThread) {
        var row = threadsByID[thread.id] ?? ThreadRow(thread: thread, isWatched: true)
        row.displayTitle = thread.displayTitle
        row.preview = thread.previewLine
        row.cwd = thread.cwd
        row.updatedAt = thread.updatedDate
        row.status = ThreadStatus(threadStatus: thread.status)
        row.isWatched = true
        threadsByID[thread.id] = row
    }

    mutating func apply(desktopSnapshot: CodexDesktopRuntimeSnapshot, observedAt: Date = Date()) {
        desktopActiveTurnCount = max(0, desktopSnapshot.activeTurnCount)
        desktopDebugSummary = desktopSnapshot.debugSummary
        overlayPendingThreads(desktopSnapshot.waitingForInputThreadIDs, status: .waitingForInput, observedAt: observedAt)
        overlayPendingThreads(desktopSnapshot.approvalThreadIDs, status: .needsApproval, observedAt: observedAt)
        overlayRunningThreads(desktopSnapshot.runningThreadIDs, observedAt: observedAt)
    }

    private mutating func overlayPendingThreads(_ threadIDs: Set<String>, status: ThreadStatus, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            updateThread(threadID: threadID) { row in
                row.status = status

                if row.updatedAt < observedAt {
                    row.updatedAt = observedAt
                }
            }
        }
    }

    private mutating func overlayRunningThreads(_ threadIDs: Set<String>, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            updateThread(threadID: threadID) { row in
                if !row.status.isPending {
                    row.status = .running
                }

                if row.updatedAt < observedAt {
                    row.updatedAt = observedAt
                }
            }
        }
    }

    mutating func apply(notification: NotificationEvent) {
        switch notification {
        case let .threadStarted(notification):
            var row = threadsByID[notification.thread.id] ?? ThreadRow(thread: notification.thread, isWatched: true)
            let previousStatus = row.status
            row.displayTitle = notification.thread.displayTitle
            row.preview = notification.thread.previewLine
            row.cwd = notification.thread.cwd
            row.updatedAt = notification.thread.updatedDate
            row.status = ThreadStatus(threadStatus: notification.thread.status)
            row.isWatched = true
            threadsByID[notification.thread.id] = row
            recordPendingResolution(threadID: notification.thread.id, previous: previousStatus, current: row.status, source: "thread/started")
        case let .threadStatusChanged(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            row.isWatched = true
            row.status = ThreadStatus(threadStatus: notification.status)
            row.updatedAt = Date()
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "thread/status/changed")
        case let .turnStarted(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            row.isWatched = true
            row.status = .running
            row.activeTurnID = notification.turn.id
            row.updatedAt = Date()
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "turn/started")
        case let .turnCompleted(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            row.isWatched = true
            row.activeTurnID = nil
            row.updatedAt = Date()

            switch notification.turn.status {
            case .completed, .interrupted:
                row.status = .idle
            case .failed:
                row.status = .failed(message: notification.turn.error?.message)
            case .inProgress:
                row.status = .running
            }

            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "turn/completed")
        case let .error(notification):
            guard !notification.willRetry else { return }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            row.isWatched = true
            row.activeTurnID = notification.turnId
            row.status = .failed(message: notification.error.message)
            row.updatedAt = Date()
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "error")
        }
    }

    mutating func apply(serverRequest: ServerRequestEvent) {
        switch serverRequest {
        case let .toolUserInput(request):
            updateThread(threadID: request.threadId) { row in
                row.isWatched = true
                row.activeTurnID = request.turnId
                row.status = .waitingForInput
                row.updatedAt = Date()
            }
        case let .approval(request):
            updateThread(threadID: request.threadId) { row in
                row.isWatched = true
                row.activeTurnID = request.turnId
                row.status = .needsApproval
                row.updatedAt = Date()
            }
        }
    }

    func notificationBody(forThreadID threadID: String, fallback: String) -> String {
        guard let thread = threadsByID[threadID] else { return fallback }
        return "\(thread.displayTitle): \(fallback)"
    }

    private func preservedStatus(current: ThreadStatus, incoming: ThreadStatus, isWatched: Bool) -> ThreadStatus? {
        guard isWatched else { return nil }

        if incoming == .notLoaded && current != .notLoaded {
            return current
        }

        if current.isPending && (incoming == .idle || incoming == .notLoaded) {
            return current
        }

        return nil
    }

    private mutating func recordPendingResolution(threadID: String, previous: ThreadStatus, current: ThreadStatus, source: String) {
        guard previous.isPending, !current.isPending else { return }
        recordDiagnostic("cleared pending thread=\(shortThreadID(threadID)) from=\(previous.displayName) to=\(current.displayName) via \(source)")
    }

    private func shortThreadID(_ threadID: String) -> String {
        String(threadID.prefix(8))
    }

    private func debugList(_ values: [String]) -> String {
        if values.isEmpty {
            return "[]"
        }

        let prefixValues = values.prefix(3)
        let suffix = values.count > prefixValues.count ? ",+\(values.count - prefixValues.count)" : ""
        return "[" + prefixValues.joined(separator: ",") + suffix + "]"
    }

    private func defaultThreadRow(threadID: String) -> ThreadRow {
        ThreadRow(
            id: threadID,
            displayTitle: threadID,
            preview: threadID,
            cwd: "",
            status: .notLoaded,
            updatedAt: Date(),
            isWatched: true,
            activeTurnID: nil
        )
    }

    private mutating func updateThread(threadID: String, update: (inout ThreadRow) -> Void) {
        var row = threadsByID[threadID] ?? defaultThreadRow(threadID: threadID)

        update(&row)
        threadsByID[threadID] = row
    }
}

private extension AppStateStore.ThreadRow {
    init(thread: CodexThread, isWatched: Bool) {
        self.id = thread.id
        self.displayTitle = thread.displayTitle
        self.preview = thread.previewLine
        self.cwd = thread.cwd
        self.status = .init(threadStatus: thread.status)
        self.updatedAt = thread.updatedDate
        self.isWatched = isWatched
        self.activeTurnID = nil
    }
}

private extension AppStateStore.ThreadStatus {
    init(threadStatus: CodexThreadStatus) {
        switch threadStatus {
        case .notLoaded:
            self = .notLoaded
        case .idle:
            self = .idle
        case .systemError:
            self = .failed(message: nil)
        case let .active(flags):
            if flags.contains(.waitingOnUserInput) {
                self = .waitingForInput
            } else if flags.contains(.waitingOnApproval) {
                self = .needsApproval
            } else {
                self = .running
            }
        }
    }
}
