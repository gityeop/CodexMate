import Foundation

struct AppStateStore {
    private static let inferredActiveTurnID = "__inferred_active_turn__"

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

        var icon: String {
            switch self {
            case .notLoaded:
                return "◌"
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
        var sessionPath: String? = nil
        var status: ThreadStatus
        var listedStatus: ThreadStatus
        var updatedAt: Date
        var statusUpdatedAt: Date = .distantPast
        var isWatched: Bool
        var activeTurnID: String?
        var lastTerminalActivityAt: Date?

        var hasActiveTurn: Bool {
            activeTurnID != nil
        }

        var displayStatus: ThreadStatus {
            hasActiveTurn ? .running : status
        }
    }

    struct ProjectSection: Equatable, Identifiable {
        let id: String
        let displayName: String
        let latestUpdatedAt: Date
        let threads: [ThreadRow]
    }

    enum NotificationEvent {
        case threadStarted(ThreadStartedNotification)
        case threadStatusChanged(ThreadStatusChangedNotification)
        case turnStarted(TurnStartedNotification)
        case turnCompleted(TurnCompletedNotification)
        case error(ErrorNotificationPayload)
        case serverRequestResolved(ServerRequestResolvedNotification)
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

    func projectSections(
        using catalog: CodexDesktopProjectCatalog,
        maxProjects: Int = .max,
        maxThreads: Int = .max
    ) -> [ProjectSection] {
        let allSections = buildProjectSections(from: recentThreads, using: catalog)
        guard maxProjects != .max || maxThreads != .max else {
            return allSections
        }

        return limitedProjectSections(allSections, maxProjects: maxProjects, maxThreads: maxThreads)
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

        if threads.contains(where: \.hasActiveTurn) {
            return .running
        }

        if threads.contains(where: {
            if case .waitingForInput = $0.displayStatus { return true }
            return false
        }) {
            return .waitingForInput
        }

        if threads.contains(where: {
            if case .needsApproval = $0.displayStatus { return true }
            return false
        }) {
            return .needsApproval
        }

        if threads.contains(where: {
            if case .running = $0.displayStatus { return true }
            return false
        }) {
            return .running
        }

        if desktopActiveTurnCount > 0 {
            return .running
        }

        if threads.contains(where: {
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
            if case .running = $0.displayStatus { return true }
            return false
        }.count
        let runningCount = max(runningThreadCount, desktopActiveTurnCount)
        let waitingCount = recentThreads.filter {
            if case .waitingForInput = $0.displayStatus { return true }
            return false
        }.count
        let approvalCount = recentThreads.filter {
            if case .needsApproval = $0.displayStatus { return true }
            return false
        }.count

        return "Recent \(recentThreads.count) | Watching \(watchedCount) | Running \(runningCount) | Reply \(waitingCount) | Approval \(approvalCount)"
    }

    var failedThreads: [ThreadRow] {
        recentThreads.filter {
            if case .failed = $0.displayStatus { return true }
            return false
        }
    }

    var debugStatusSnapshot: String {
        let waitingThreadIDs = recentThreads.compactMap { thread in
            if case .waitingForInput = thread.displayStatus { return shortThreadID(thread.id) }
            return nil
        }
        let approvalThreadIDs = recentThreads.compactMap { thread in
            if case .needsApproval = thread.displayStatus { return shortThreadID(thread.id) }
            return nil
        }
        let runningThreadIDs = recentThreads.compactMap { thread in
            if case .running = thread.displayStatus { return shortThreadID(thread.id) }
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
            let previousStatus = row.status
            let currentUpdatedAt = row.updatedAt
            let currentStatusUpdatedAt = row.statusUpdatedAt
            let incomingUpdatedAt = thread.updatedDate
            row.displayTitle = thread.displayTitle
            row.preview = thread.previewLine
            row.cwd = thread.cwd
            row.sessionPath = thread.path

            let newStatus = ThreadStatus(threadStatus: thread.status)
            row.listedStatus = newStatus
            let preservedStatus = preservedStatus(
                current: row.status,
                incoming: newStatus,
                isWatched: row.isWatched,
                activeTurnID: row.activeTurnID,
                currentStatusUpdatedAt: currentStatusUpdatedAt,
                incomingUpdatedAt: incomingUpdatedAt
            )
            if let preservedStatus {
                if row.status.isPending && (newStatus == .idle || newStatus == .notLoaded) {
                    recordDiagnostic("preserved pending thread=\(shortThreadID(thread.id)) kept=\(row.status.displayName) incoming=\(newStatus.displayName)")
                }
                row.status = preservedStatus
            } else {
                row.status = newStatus
            }
            row.updatedAt = max(currentUpdatedAt, incomingUpdatedAt)
            row.statusUpdatedAt = max(currentStatusUpdatedAt, incomingUpdatedAt)

            if row.isWatched {
                row.activeTurnID = updatedActiveTurnID(
                    existing: row.activeTurnID,
                    status: row.status,
                    allowClearing: false
                )
            }

            if row.lastTerminalActivityAt == nil,
               row.isWatched,
               row.activeTurnID == nil,
               shouldInferTerminalActivity(previous: previousStatus, current: row.status) {
                row.lastTerminalActivityAt = row.updatedAt
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
        let currentUpdatedAt = row.updatedAt
        let currentStatusUpdatedAt = row.statusUpdatedAt
        let incomingUpdatedAt = thread.updatedDate
        row.displayTitle = thread.displayTitle
        row.preview = thread.previewLine
        row.cwd = thread.cwd
        row.sessionPath = thread.path
        let newStatus = ThreadStatus(threadStatus: thread.status)
        let preservedStatus = preservedStatus(
            current: row.status,
            incoming: newStatus,
            isWatched: true,
            activeTurnID: row.activeTurnID,
            currentStatusUpdatedAt: currentStatusUpdatedAt,
            incomingUpdatedAt: incomingUpdatedAt
        )
        row.updatedAt = max(currentUpdatedAt, incomingUpdatedAt)
        row.statusUpdatedAt = max(currentStatusUpdatedAt, incomingUpdatedAt)
        row.status = preservedStatus ?? newStatus
        row.listedStatus = newStatus
        row.isWatched = true
        row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.status, allowClearing: true)
        if row.lastTerminalActivityAt == nil,
           row.activeTurnID == nil,
           isUnreadEligibleTerminalStatus(row.status) {
            row.lastTerminalActivityAt = row.updatedAt
        }
        threadsByID[thread.id] = row
    }

    mutating func apply(desktopSnapshot: CodexDesktopRuntimeSnapshot, observedAt: Date = Date()) {
        desktopActiveTurnCount = max(0, desktopSnapshot.activeTurnCount)
        desktopDebugSummary = desktopSnapshot.debugSummary
        reconcilePendingThreads(
            pendingThreadIDs: desktopSnapshot.waitingForInputThreadIDs.union(desktopSnapshot.approvalThreadIDs),
            runningThreadIDs: desktopSnapshot.runningThreadIDs,
            observedAt: observedAt
        )
        overlayFailedThreads(desktopSnapshot.failedThreads)
        overlayPendingThreads(desktopSnapshot.waitingForInputThreadIDs, status: .waitingForInput, observedAt: observedAt)
        overlayPendingThreads(desktopSnapshot.approvalThreadIDs, status: .needsApproval, observedAt: observedAt)
        overlayRunningThreads(desktopSnapshot.runningThreadIDs, observedAt: observedAt)
    }

    private mutating func reconcilePendingThreads(
        pendingThreadIDs: Set<String>,
        runningThreadIDs: Set<String>,
        observedAt: Date = Date()
    ) {
        for threadID in threadsByID.keys.sorted() {
            guard var row = threadsByID[threadID], row.status.isPending, !pendingThreadIDs.contains(threadID) else {
                continue
            }

            guard !(row.isWatched && row.hasActiveTurn) else {
                continue
            }

            let previousStatus = row.status
            if runningThreadIDs.contains(threadID) {
                row.status = .running
            } else {
                row.status = row.listedStatus
            }
            row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)

            guard row.status != previousStatus else { continue }
            threadsByID[threadID] = row
            recordDiagnostic("cleared stale pending thread=\(shortThreadID(threadID)) from=\(previousStatus.displayName) to=\(row.status.displayName) via desktop snapshot")
        }
    }

    private mutating func overlayPendingThreads(_ threadIDs: Set<String>, status: ThreadStatus, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            updateThread(threadID: threadID) { row in
                guard !(row.isWatched && row.hasActiveTurn) else {
                    return
                }

                row.status = status
                row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            }
        }
    }

    private mutating func overlayFailedThreads(_ failures: [String: CodexDesktopRuntimeSnapshot.FailedThreadState]) {
        guard !failures.isEmpty else { return }

        for (threadID, failure) in failures {
            updateThread(threadID: threadID) { row in
                guard !(row.isWatched && row.hasActiveTurn) else {
                    return
                }

                guard row.updatedAt <= failure.loggedAt else {
                    return
                }

                switch row.status {
                case .waitingForInput, .needsApproval, .running:
                    return
                case .notLoaded, .idle, .failed:
                    row.status = .failed(message: failure.message)
                }

                row.statusUpdatedAt = max(row.statusUpdatedAt, failure.loggedAt)
                if row.updatedAt < failure.loggedAt {
                    row.updatedAt = failure.loggedAt
                }
            }
        }
    }

    private mutating func overlayRunningThreads(_ threadIDs: Set<String>, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            updateThread(threadID: threadID) { row in
                guard !(row.isWatched && row.hasActiveTurn) else {
                    return
                }

                if !row.status.isPending {
                    row.status = .running
                }
                row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
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
            row.sessionPath = notification.thread.path
            row.updatedAt = max(row.updatedAt, notification.thread.updatedDate)
            row.statusUpdatedAt = max(row.statusUpdatedAt, notification.thread.updatedDate)
            row.status = ThreadStatus(threadStatus: notification.thread.status)
            row.listedStatus = row.status
            row.isWatched = true
            row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.status, allowClearing: false)
            threadsByID[notification.thread.id] = row
            recordPendingResolution(threadID: notification.thread.id, previous: previousStatus, current: row.status, source: "thread/started")
        case let .threadStatusChanged(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            row.isWatched = true
            row.status = ThreadStatus(threadStatus: notification.status)
            row.listedStatus = row.status
            row.statusUpdatedAt = Date()
            row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.status, allowClearing: false)
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "thread/status/changed")
        case let .turnStarted(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            let observedAt = Date()
            row.isWatched = true
            row.status = .running
            row.listedStatus = .running
            row.activeTurnID = notification.turn.id
            row.updatedAt = max(row.updatedAt, observedAt)
            row.statusUpdatedAt = observedAt
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "turn/started")
        case let .turnCompleted(notification):
            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            let observedAt = Date()
            row.isWatched = true
            row.activeTurnID = nil
            row.updatedAt = max(row.updatedAt, observedAt)
            row.statusUpdatedAt = observedAt
            row.lastTerminalActivityAt = row.updatedAt

            switch notification.turn.status {
            case .completed, .interrupted:
                row.status = .idle
            case .failed:
                row.status = .failed(message: notification.turn.error?.message)
            case .inProgress:
                row.status = .running
            }
            row.listedStatus = row.status

            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "turn/completed")
        case let .error(notification):
            guard !notification.willRetry else { return }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.status
            let observedAt = Date()
            row.isWatched = true
            row.activeTurnID = nil
            row.status = .failed(message: notification.error.message)
            row.listedStatus = row.status
            row.updatedAt = max(row.updatedAt, observedAt)
            row.statusUpdatedAt = observedAt
            row.lastTerminalActivityAt = row.updatedAt
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "error")
        case let .serverRequestResolved(notification):
            guard var row = threadsByID[notification.threadId], row.status.isPending else {
                return
            }

            let previousStatus = row.status
            row.status = row.hasActiveTurn ? .running : row.listedStatus
            row.statusUpdatedAt = Date()
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.status, source: "serverRequest/resolved")
        }
    }

    mutating func apply(serverRequest: ServerRequestEvent) {
        switch serverRequest {
        case let .toolUserInput(request):
            updateThread(threadID: request.threadId) { row in
                let observedAt = Date()
                row.isWatched = true
                row.activeTurnID = request.turnId
                row.status = .waitingForInput
                row.updatedAt = max(row.updatedAt, observedAt)
                row.statusUpdatedAt = observedAt
            }
        case let .approval(request):
            updateThread(threadID: request.threadId) { row in
                let observedAt = Date()
                row.isWatched = true
                row.activeTurnID = request.turnId
                row.status = .needsApproval
                row.updatedAt = max(row.updatedAt, observedAt)
                row.statusUpdatedAt = observedAt
            }
        }
    }

    func notificationBody(forThreadID threadID: String, fallback: String) -> String {
        guard let thread = threadsByID[threadID] else { return fallback }
        return "\(thread.displayTitle): \(fallback)"
    }

    private func preservedStatus(
        current: ThreadStatus,
        incoming: ThreadStatus,
        isWatched: Bool,
        activeTurnID: String?,
        currentStatusUpdatedAt: Date,
        incomingUpdatedAt: Date
    ) -> ThreadStatus? {
        if activeTurnID != nil {
            return current
        }

        if shouldPreserveNewerRuntimeStatus(
            current: current,
            incoming: incoming,
            currentStatusUpdatedAt: currentStatusUpdatedAt,
            incomingUpdatedAt: incomingUpdatedAt
        ) {
            return current
        }

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
            sessionPath: nil,
            status: .notLoaded,
            listedStatus: .notLoaded,
            updatedAt: Date(),
            statusUpdatedAt: Date(),
            isWatched: true,
            activeTurnID: nil,
            lastTerminalActivityAt: nil
        )
    }

    private mutating func updateThread(threadID: String, update: (inout ThreadRow) -> Void) {
        var row = threadsByID[threadID] ?? defaultThreadRow(threadID: threadID)

        update(&row)
        threadsByID[threadID] = row
    }

    private func buildProjectSections(
        from threads: [ThreadRow],
        using catalog: CodexDesktopProjectCatalog
    ) -> [ProjectSection] {
        struct Bucket {
            let id: String
            let displayName: String
            var latestUpdatedAt: Date
            var threads: [ThreadRow]
        }

        var buckets: [String: Bucket] = [:]

        for thread in threads {
            let project = catalog.project(for: thread.cwd)
            if var bucket = buckets[project.id] {
                if thread.updatedAt > bucket.latestUpdatedAt {
                    bucket.latestUpdatedAt = thread.updatedAt
                }
                bucket.threads.append(thread)
                buckets[project.id] = bucket
            } else {
                buckets[project.id] = Bucket(
                    id: project.id,
                    displayName: project.displayName,
                    latestUpdatedAt: thread.updatedAt,
                    threads: [thread]
                )
            }
        }

        return buckets.values
            .map { bucket in
                ProjectSection(
                    id: bucket.id,
                    displayName: bucket.displayName,
                    latestUpdatedAt: bucket.latestUpdatedAt,
                    threads: bucket.threads
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
            }
    }

    private func limitedProjectSections(
        _ sections: [ProjectSection],
        maxProjects: Int,
        maxThreads: Int
    ) -> [ProjectSection] {
        guard maxThreads > 0 else { return [] }

        let failedProjectIDs = Set(
            sections.compactMap { section in
                section.threads.contains(where: Self.isFailedThread) ? section.id : nil
            }
        )
        let limitedProjectIDs = Set(
            sections
                .filter { failedProjectIDs.contains($0.id) }
                .map(\.id)
                + sections
                    .filter { !failedProjectIDs.contains($0.id) }
                    .prefix(maxProjectsExcludingFailures(maxProjects: maxProjects, failedProjectIDs: failedProjectIDs))
                    .map(\.id)
        )
        let limitedSections = sections.filter { limitedProjectIDs.contains($0.id) }
        let threadProjectIDs = Dictionary(
            uniqueKeysWithValues: limitedSections.flatMap { section in
                section.threads.map { ($0.id, section.id) }
            }
        )
        var visibleThreadsByProject: [String: [ThreadRow]] = [:]
        var visibleThreadIDs: Set<String> = []
        var visibleThreadCount = 0

        let failedThreads = limitedSections
            .flatMap(\.threads)
            .filter(Self.isFailedThread)
            .sorted(by: Self.isNewerThread)

        for thread in failedThreads {
            guard visibleThreadCount < maxThreads else { break }

            let projectID = threadProjectIDs[thread.id]
            guard let projectID else { continue }

            visibleThreadsByProject[projectID, default: []].append(thread)
            visibleThreadIDs.insert(thread.id)
            visibleThreadCount += 1
        }

        for section in limitedSections {
            guard visibleThreadCount < maxThreads,
                  let thread = section.threads.first(where: { !visibleThreadIDs.contains($0.id) })
            else {
                break
            }

            visibleThreadsByProject[section.id, default: []].append(thread)
            visibleThreadIDs.insert(thread.id)
            visibleThreadCount += 1
        }

        let remainingThreads = limitedSections
            .flatMap(\.threads)
            .filter { !visibleThreadIDs.contains($0.id) }
            .sorted(by: Self.isNewerThread)

        for thread in remainingThreads.prefix(max(0, maxThreads - visibleThreadCount)) {
            let projectID = threadProjectIDs[thread.id]
            guard let projectID else { continue }
            visibleThreadsByProject[projectID, default: []].append(thread)
        }

        return limitedSections.compactMap { section in
            guard let visibleThreads = visibleThreadsByProject[section.id], !visibleThreads.isEmpty else {
                return nil
            }

            return ProjectSection(
                id: section.id,
                displayName: section.displayName,
                latestUpdatedAt: section.latestUpdatedAt,
                threads: visibleThreads.sorted(by: Self.isNewerThread)
            )
        }
    }

    private static func isNewerThread(_ lhs: ThreadRow, _ rhs: ThreadRow) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.updatedAt > rhs.updatedAt
    }

    private static func isFailedThread(_ thread: ThreadRow) -> Bool {
        if case .failed = thread.displayStatus { return true }
        return false
    }

    private func maxProjectsExcludingFailures(maxProjects: Int, failedProjectIDs: Set<String>) -> Int {
        guard maxProjects != .max else { return .max }
        return max(0, maxProjects - failedProjectIDs.count)
    }

    private func shouldPreserveNewerRuntimeStatus(
        current: ThreadStatus,
        incoming: ThreadStatus,
        currentStatusUpdatedAt: Date,
        incomingUpdatedAt: Date
    ) -> Bool {
        guard currentStatusUpdatedAt > incomingUpdatedAt else {
            return false
        }

        guard incoming == .idle || incoming == .notLoaded else {
            return false
        }

        switch current {
        case .running, .waitingForInput, .needsApproval, .failed:
            return true
        case .idle, .notLoaded:
            return false
        }
    }

    private func shouldInferTerminalActivity(previous: ThreadStatus, current: ThreadStatus) -> Bool {
        if previous == current {
            return isUnreadEligibleTerminalStatus(current)
        }

        if previous == .running || previous.isPending {
            return isUnreadEligibleTerminalStatus(current)
        }

        return false
    }

    private func isUnreadEligibleTerminalStatus(_ status: ThreadStatus) -> Bool {
        switch status {
        case .idle, .failed:
            return true
        case .notLoaded, .waitingForInput, .running, .needsApproval:
            return false
        }
    }

    private func updatedActiveTurnID(existing: String?, status: ThreadStatus, allowClearing: Bool) -> String? {
        switch status {
        case .running, .waitingForInput, .needsApproval:
            return existing ?? Self.inferredActiveTurnID
        case .notLoaded, .idle, .failed:
            return allowClearing ? nil : existing
        }
    }

}

private extension AppStateStore.ThreadRow {
    init(thread: CodexThread, isWatched: Bool) {
        self.id = thread.id
        self.displayTitle = thread.displayTitle
        self.preview = thread.previewLine
        self.cwd = thread.cwd
        self.sessionPath = thread.path
        self.status = .init(threadStatus: thread.status)
        self.listedStatus = self.status
        self.updatedAt = thread.updatedDate
        self.statusUpdatedAt = thread.updatedDate
        self.isWatched = isWatched
        self.activeTurnID = nil
        self.lastTerminalActivityAt = nil
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
