import Foundation

struct AppStateStore {
    private enum ProjectMenuLimit {
        static let maxSections = 6
        static let maxThreadsPerSection = 5
    }

    private enum ProjectPanelLimit {
        static let maxThreadsPerProject = 5
    }

    private enum ProjectBadgeLimit {
        static let maxVisibleBadges = 4
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(binaryPath: String)
        case failed(message: String)
    }

    enum OverallStatus: Equatable {
        case connecting
        case idle
        case running
        case waitingForInput
        case needsApproval
        case failed

        var icon: String {
            switch self {
            case .connecting:
                return "⏳"
            case .idle:
                return "✅"
            case .running:
                return "⏳"
            case .waitingForInput:
                return "💬"
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
            case .running:
                return "Running"
            case .waitingForInput:
                return "Waiting for input"
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
        case running
        case waitingForInput
        case needsApproval
        case failed(message: String?)

        var displayName: String {
            switch self {
            case .notLoaded:
                return "Not loaded"
            case .idle:
                return "Idle"
            case .running:
                return "Running"
            case .waitingForInput:
                return "Waiting for input"
            case .needsApproval:
                return "Needs approval"
            case .failed:
                return "Failed"
            }
        }
    }

    enum StatusIconAnimationMode: Equatable {
        case idle
        case alert
    }

    struct ProjectSection: Equatable, Identifiable {
        let id: String
        let displayName: String
        let latestUpdatedAt: Date
        let totalThreadCount: Int
        let threads: [ThreadRow]

        var headerTitle: String {
            let label = totalThreadCount == 1 ? "thread" : "threads"
            return "\(displayName) | \(totalThreadCount) \(label)"
        }
    }

    struct ProjectBadge: Equatable, Identifiable {
        let id: String
        let displayName: String
        let title: String
        let latestUpdatedAt: Date
        let status: ThreadStatus
        let threadID: String?
    }

    struct ProjectPanel: Equatable, Identifiable {
        let id: String
        let displayName: String
        let latestUpdatedAt: Date
        let dominantStatus: ThreadStatus
        let waitingForInputCount: Int
        let approvalCount: Int
        let runningCount: Int
        let failedCount: Int
        let totalThreadCount: Int
        let hiddenThreadCount: Int
        let threads: [ThreadRow]

        var actionableCount: Int {
            waitingForInputCount + approvalCount
        }
    }

    private struct ProjectGroup {
        let id: String
        let displayName: String
        let latestUpdatedAt: Date
        let totalThreadCount: Int
        let threads: [ThreadRow]
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
    private(set) var desktopRunningThreadIDs: Set<String> = []
    private(set) var desktopHasInProgressActivity = false
    private(set) var desktopLastAppServerEvent: String?
    private(set) var lastDesktopObservationAt: Date?
    private(set) var projectCatalog: CodexDesktopProjectCatalog = .empty

    var recentThreads: [ThreadRow] {
        threadsByID.values
            .map(resolvedThread)
            .sorted(by: Self.threadSort)
    }

    var savedProjectCount: Int {
        projectCatalog.savedProjectCount
    }

    var actionableThreadCount: Int {
        recentThreads.reduce(into: 0) { partialResult, thread in
            if Self.isActionable(thread.status) {
                partialResult += 1
            }
        }
    }

    var statusIconAnimationMode: StatusIconAnimationMode {
        actionableThreadCount > 0 ? .alert : .idle
    }

    var debugTrackedStatusSummary: String {
        let waiting = recentThreads.filter {
            if case .waitingForInput = $0.status { return true }
            return false
        }
        let approval = recentThreads.filter {
            if case .needsApproval = $0.status { return true }
            return false
        }
        let running = recentThreads.filter {
            if case .running = $0.status { return true }
            return false
        }

        return [
            "waiting=[\(waiting.map(Self.debugThreadDescriptor).joined(separator: ", "))]",
            "approval=[\(approval.map(Self.debugThreadDescriptor).joined(separator: ", "))]",
            "running=[\(running.map(Self.debugThreadDescriptor).joined(separator: ", "))]"
        ].joined(separator: " ")
    }

    var projectSections: [ProjectSection] {
        projectGroups
            .sorted { lhs, rhs in
                if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
            }
            .prefix(ProjectMenuLimit.maxSections)
            .map { group in
                ProjectSection(
                    id: group.id,
                    displayName: group.displayName,
                    latestUpdatedAt: group.latestUpdatedAt,
                    totalThreadCount: group.totalThreadCount,
                    threads: Array(group.threads.prefix(ProjectMenuLimit.maxThreadsPerSection))
                )
            }
    }

    var projectBadges: [ProjectBadge] {
        let badgesFromThreads: [ProjectBadge] = projectGroups
            .compactMap { group -> ProjectBadge? in
                let badgeThread = group.threads
                    .sorted(by: Self.projectBadgeThreadSort)
                    .first

                guard let thread = badgeThread else { return nil }

                return ProjectBadge(
                    id: group.id,
                    displayName: group.displayName,
                    title: "\(Self.statusIcon(for: thread.status)) \(Self.compactProjectName(group.displayName))",
                    latestUpdatedAt: group.latestUpdatedAt,
                    status: thread.status,
                    threadID: thread.id
                )
            }
            .sorted { (lhs: ProjectBadge, rhs: ProjectBadge) in
                let lhsPriority = Self.projectBadgePriority(for: lhs.status)
                let rhsPriority = Self.projectBadgePriority(for: rhs.status)

                if lhsPriority == rhsPriority {
                    if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }

                    return lhs.latestUpdatedAt > rhs.latestUpdatedAt
                }

                return lhsPriority < rhsPriority
            }

        var combinedBadges: [ProjectBadge] = badgesFromThreads
        let seenProjectIDs = Set(combinedBadges.map { $0.id })

        for project in projectCatalog.allProjectsForBadges where combinedBadges.count < ProjectBadgeLimit.maxVisibleBadges {
            guard !seenProjectIDs.contains(project.id) else { continue }

            combinedBadges.append(
                ProjectBadge(
                    id: project.id,
                    displayName: project.displayName,
                    title: "\(Self.statusIcon(for: .idle)) \(Self.compactProjectName(project.displayName))",
                    latestUpdatedAt: .distantPast,
                    status: .idle,
                    threadID: nil
                )
            )
        }

        return Array(combinedBadges.prefix(ProjectBadgeLimit.maxVisibleBadges))
    }

    var panelProjects: [ProjectPanel] {
        projectGroups
            .map { group in
                let displayedThreads = Array(group.threads.prefix(ProjectPanelLimit.maxThreadsPerProject))
                let waitingForInputCount = group.threads.filter {
                    if case .waitingForInput = $0.status { return true }
                    return false
                }.count
                let approvalCount = group.threads.filter {
                    if case .needsApproval = $0.status { return true }
                    return false
                }.count
                let runningCount = group.threads.filter {
                    if case .running = $0.status { return true }
                    return false
                }.count
                let failedCount = group.threads.filter {
                    if case .failed = $0.status { return true }
                    return false
                }.count

                return ProjectPanel(
                    id: group.id,
                    displayName: group.displayName,
                    latestUpdatedAt: group.latestUpdatedAt,
                    dominantStatus: Self.dominantPanelStatus(in: group.threads),
                    waitingForInputCount: waitingForInputCount,
                    approvalCount: approvalCount,
                    runningCount: runningCount,
                    failedCount: failedCount,
                    totalThreadCount: group.totalThreadCount,
                    hiddenThreadCount: max(0, group.totalThreadCount - displayedThreads.count),
                    threads: displayedThreads
                )
            }
            .sorted { lhs, rhs in
                let lhsIsActionable = lhs.actionableCount > 0
                let rhsIsActionable = rhs.actionableCount > 0

                if lhsIsActionable != rhsIsActionable {
                    return lhsIsActionable
                }

                if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
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

        if desktopHasInProgressActivity {
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
        let inferredRunningCount = max(desktopActiveTurnCount, desktopHasInProgressActivity ? 1 : 0)
        let runningCount = max(runningThreadCount, inferredRunningCount)
        let waitingForInputCount = recentThreads.filter {
            if case .waitingForInput = $0.status { return true }
            return false
        }.count
        let approvalCount = recentThreads.filter {
            if case .needsApproval = $0.status { return true }
            return false
        }.count

        return "Recent \(recentThreads.count) | Watching \(watchedCount) | Running \(runningCount) | Waiting \(waitingForInputCount) | Approval \(approvalCount)"
    }

    mutating func setConnection(_ connection: ConnectionState) {
        self.connection = connection
    }

    mutating func setProjectCatalog(_ projectCatalog: CodexDesktopProjectCatalog) {
        self.projectCatalog = projectCatalog
    }

    mutating func recordDiagnostic(_ diagnostic: String) {
        let compact = diagnostic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        guard !compact.isEmpty else { return }
        lastDiagnostic = compact
    }

    @discardableResult
    mutating func replaceRecentThreads(with threads: [CodexThread]) -> [String] {
        var updatedThreads: [String: ThreadRow] = [:]
        var debugMessages: [String] = []

        for thread in threads {
            var row = threadsByID[thread.id] ?? ThreadRow(thread: thread, isWatched: false)
            let previousStatus = row.status
            row.displayTitle = thread.displayTitle
            row.preview = thread.previewLine
            row.cwd = thread.cwd
            row.updatedAt = thread.updatedDate

            let newStatus = ThreadStatus(threadStatus: thread.status)
            if Self.shouldPreservePendingStatus(current: previousStatus, incoming: newStatus, isWatched: row.isWatched, activeTurnID: row.activeTurnID) {
                row.status = previousStatus
                debugMessages.append(
                    "preserved pending status thread=\(thread.id) current=\(previousStatus.displayName) incoming=\(newStatus.displayName)"
                )
            } else if row.isWatched && newStatus == .notLoaded && previousStatus != .notLoaded {
                if previousStatus == .running && !desktopRunningThreadIDs.contains(thread.id) {
                    row.status = .idle
                } else {
                    row.status = newStatus
                }
            } else {
                row.status = newStatus
            }

            updatedThreads[thread.id] = row
        }

        for (threadID, row) in threadsByID where row.isWatched && updatedThreads[threadID] == nil {
            updatedThreads[threadID] = row
        }

        threadsByID = updatedThreads
        return debugMessages
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
        desktopRunningThreadIDs = desktopSnapshot.runningThreadIDs
        desktopHasInProgressActivity = desktopSnapshot.hasInProgressActivity
        desktopLastAppServerEvent = desktopSnapshot.lastAppServerEvent
        lastDesktopObservationAt = observedAt
    }

    mutating func apply(notification: NotificationEvent) {
        switch notification {
        case let .threadStarted(notification):
            var row = threadsByID[notification.thread.id] ?? ThreadRow(thread: notification.thread, isWatched: true)
            row.displayTitle = notification.thread.displayTitle
            row.preview = notification.thread.previewLine
            row.cwd = notification.thread.cwd
            row.updatedAt = notification.thread.updatedDate
            row.status = ThreadStatus(threadStatus: notification.thread.status)
            row.isWatched = true
            threadsByID[notification.thread.id] = row
        case let .threadStatusChanged(notification):
            updateThread(threadID: notification.threadId) { row in
                row.isWatched = true
                row.status = ThreadStatus(threadStatus: notification.status)
                row.updatedAt = Date()
            }
        case let .turnStarted(notification):
            updateThread(threadID: notification.threadId) { row in
                row.isWatched = true
                row.status = .running
                row.activeTurnID = notification.turn.id
                row.updatedAt = Date()
            }
        case let .turnCompleted(notification):
            updateThread(threadID: notification.threadId) { row in
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
            }
        case let .error(notification):
            guard !notification.willRetry else { return }

            updateThread(threadID: notification.threadId) { row in
                row.isWatched = true
                row.activeTurnID = notification.turnId
                row.status = .failed(message: notification.error.message)
                row.updatedAt = Date()
            }
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

    private mutating func updateThread(threadID: String, update: (inout ThreadRow) -> Void) {
        var row = threadsByID[threadID] ?? ThreadRow(
            id: threadID,
            displayTitle: threadID,
            preview: threadID,
            cwd: "",
            status: .notLoaded,
            updatedAt: Date(),
            isWatched: true,
            activeTurnID: nil
        )

        update(&row)
        threadsByID[threadID] = row
    }

    private func resolvedThread(_ row: ThreadRow) -> ThreadRow {
        var resolved = row
        resolved.status = effectiveStatus(for: row)

        if desktopRunningThreadIDs.contains(row.id), let observedAt = lastDesktopObservationAt, resolved.updatedAt < observedAt {
            resolved.updatedAt = observedAt
        }

        return resolved
    }

    private var projectGroups: [ProjectGroup] {
        let threads = recentThreads
        guard !threads.isEmpty else { return [] }

        var buckets: [String: (displayName: String, latestUpdatedAt: Date, threads: [ThreadRow], totalCount: Int)] = [:]

        for thread in threads {
            let project = projectCatalog.project(for: thread.cwd)
            var bucket = buckets[project.id] ?? (
                displayName: project.displayName,
                latestUpdatedAt: thread.updatedAt,
                threads: [ThreadRow](),
                totalCount: 0
            )

            bucket.threads.append(thread)
            bucket.totalCount += 1

            if thread.updatedAt > bucket.latestUpdatedAt {
                bucket.latestUpdatedAt = thread.updatedAt
            }

            buckets[project.id] = bucket
        }

        return buckets.map { key, bucket in
            ProjectGroup(
                id: key,
                displayName: bucket.displayName,
                latestUpdatedAt: bucket.latestUpdatedAt,
                totalThreadCount: bucket.totalCount,
                threads: bucket.threads.sorted(by: Self.threadSort)
            )
        }
    }

    private func effectiveStatus(for row: ThreadRow) -> ThreadStatus {
        switch row.status {
        case .waitingForInput, .needsApproval, .failed:
            return row.status
        case .running:
            if desktopRunningThreadIDs.contains(row.id) {
                return .running
            }

            if desktopActiveTurnCount > 0, row.activeTurnID != nil {
                return .running
            }

            if let observedAt = lastDesktopObservationAt, row.updatedAt < observedAt {
                return .idle
            }

            return .running
        case .idle, .notLoaded:
            if desktopRunningThreadIDs.contains(row.id) {
                return .running
            }

            return row.status
        }
    }

    private static func threadSort(_ lhs: ThreadRow, _ rhs: ThreadRow) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.updatedAt > rhs.updatedAt
    }

    private static func compactProjectName(_ displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Project" }

        if trimmed.count <= 5 {
            return trimmed
        }

        return String(trimmed.prefix(4)) + "…"
    }

    private static func statusIcon(for status: ThreadStatus) -> String {
        switch status {
        case .waitingForInput:
            return "💬"
        case .needsApproval:
            return "🟡"
        case .running:
            return "⏳"
        case .failed:
            return "⚠️"
        case .idle, .notLoaded:
            return "✅"
        }
    }

    private static func projectBadgePriority(for status: ThreadStatus) -> Int {
        switch status {
        case .waitingForInput:
            return 0
        case .needsApproval:
            return 1
        case .running:
            return 2
        case .failed:
            return 3
        case .idle, .notLoaded:
            return 4
        }
    }

    private static func projectBadgeThreadSort(_ lhs: ThreadRow, _ rhs: ThreadRow) -> Bool {
        let lhsPriority = projectBadgePriority(for: lhs.status)
        let rhsPriority = projectBadgePriority(for: rhs.status)

        if lhsPriority == rhsPriority {
            return threadSort(lhs, rhs)
        }

        return lhsPriority < rhsPriority
    }

    private static func dominantPanelStatus(in threads: [ThreadRow]) -> ThreadStatus {
        threads
            .sorted { lhs, rhs in
                let lhsPriority = panelStatusPriority(for: lhs.status)
                let rhsPriority = panelStatusPriority(for: rhs.status)

                if lhsPriority == rhsPriority {
                    return threadSort(lhs, rhs)
                }

                return lhsPriority < rhsPriority
            }
            .first?
            .status ?? .idle
    }

    private static func panelStatusPriority(for status: ThreadStatus) -> Int {
        switch status {
        case .waitingForInput:
            return 0
        case .needsApproval:
            return 1
        case .failed:
            return 2
        case .running:
            return 3
        case .idle, .notLoaded:
            return 4
        }
    }

    private static func isActionable(_ status: ThreadStatus) -> Bool {
        switch status {
        case .waitingForInput, .needsApproval:
            return true
        case .notLoaded, .idle, .running, .failed:
            return false
        }
    }

    private static func shouldPreservePendingStatus(
        current: ThreadStatus,
        incoming: ThreadStatus,
        isWatched: Bool,
        activeTurnID: String?
    ) -> Bool {
        guard isWatched, activeTurnID != nil, isActionable(current) else {
            return false
        }

        switch incoming {
        case .idle, .notLoaded:
            return true
        case .running, .waitingForInput, .needsApproval, .failed:
            return false
        }
    }

    private static func debugThreadDescriptor(_ thread: ThreadRow) -> String {
        let shortID = String(thread.id.prefix(8))
        let watchedMarker = thread.isWatched ? "*" : ""
        let turnMarker = thread.activeTurnID == nil ? "" : "@"
        return "\(shortID)\(watchedMarker)\(turnMarker)"
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
