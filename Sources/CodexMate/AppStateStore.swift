import Foundation

struct AppStateStore {
    private static let inferredActiveTurnID = "__inferred_active_turn__"
    private static let watchedRunningReconciliationGraceInterval: TimeInterval = 5
    private static let watchedPendingReconciliationGraceInterval: TimeInterval = 5
    private static let watchedFailedReconciliationGraceInterval: TimeInterval = 5
    private static let desktopActiveTurnSafetyTimeout: TimeInterval = 30 * 60
    private static let archivedThreadTombstoneTTL: TimeInterval = 120
    private static let completionHintClockTolerance: TimeInterval = 5

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(binaryPath: String)
        case failed(message: String)

        var isConnected: Bool {
            if case .connected = self {
                return true
            }

            return false
        }

        var isFailed: Bool {
            if case .failed = self {
                return true
            }

            return false
        }
    }

    enum OverallStatus: Equatable {
        case connecting
        case idle
        case waitingForUser
        case running
        case failed

        var icon: String {
            switch self {
            case .connecting:
                return "⏳"
            case .idle:
                return "✅"
            case .waitingForUser:
                return "💬"
            case .running:
                return "⏳"
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
            case .waitingForUser:
                return "Waiting for user"
            case .running:
                return "Running"
            case .failed:
                return "Failed"
            }
        }
    }

    enum PresentationStatus: Equatable {
        case notLoaded
        case idle
        case waitingForUser
        case running
        case failed
    }

    enum RuntimePhase: Equatable {
        case none
        case running
    }

    enum PendingRequestKind: Equatable {
        case userInput
        case approval

        var status: ThreadStatus {
            switch self {
            case .userInput:
                return .waitingForInput
            case .approval:
                return .needsApproval
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
                return "💬"
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
        var isSubagent = false
        var parentThreadID: String? = nil
        var agentNickname: String? = nil
        var status: ThreadStatus
        var listedStatus: ThreadStatus
        var updatedAt: Date
        var statusUpdatedAt: Date = .distantPast
        var authoritativeListPresence: AuthoritativeListPresence = .listed
        var authoritativeListOmissionCount = 0
        var isWatched: Bool
        var runtimePhase: RuntimePhase = .none
        var pendingRequestKind: PendingRequestKind?
        var pendingRequestReason: String?
        var lastRuntimeEventAt: Date?
        var activeTurnID: String?
        var lastTerminalActivityAt: Date?
        var hasInferredTerminalActivity = false

        var hasActiveTurn: Bool {
            activeTurnID != nil
        }

        var activityUpdatedAt: Date {
            let terminalActivityAt = max(updatedAt, lastTerminalActivityAt ?? .distantPast)

            switch presentationStatus {
            case .running, .waitingForUser:
                return max(terminalActivityAt, lastRuntimeEventAt ?? .distantPast)
            case .idle, .notLoaded, .failed:
                return terminalActivityAt
            }
        }

        var displayStatus: ThreadStatus {
            if let pendingRequestKind {
                return pendingRequestKind.status
            }

            if runtimePhase == .running {
                return .running
            }

            return status
        }

        var presentationStatus: PresentationStatus {
            switch displayStatus {
            case .notLoaded:
                return .notLoaded
            case .idle:
                return .idle
            case .waitingForInput, .needsApproval:
                return .waitingForUser
            case .running:
                return .running
            case .failed:
                return .failed
            }
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
        case threadArchived(ThreadArchivedNotification)
        case threadUnarchived(ThreadUnarchivedNotification)
        case threadNameUpdated(ThreadNameUpdatedNotification)
        case turnStarted(TurnStartedNotification)
        case itemStarted(ItemStartedNotification)
        case turnCompleted(TurnCompletedNotification)
        case error(ErrorNotificationPayload)
        case serverRequestResolved(ServerRequestResolvedNotification)
    }

    enum ServerRequestEvent {
        case toolUserInput(ToolRequestUserInputRequest)
        case approval(ApprovalRequestPayload)
    }

    enum AuthoritativeListPresence: Equatable {
        case listed
        case pendingInclusion
    }

    private final class ThreadOrderingCache {
        var recentThreads: [ThreadRow]?
        var visibleRecentThreads: [ThreadRow]?

        func invalidate() {
            recentThreads = nil
            visibleRecentThreads = nil
        }
    }

    private(set) var connection: ConnectionState = .disconnected
    private(set) var threadsByID: [String: ThreadRow] = [:] {
        didSet {
            threadOrderingCache.invalidate()
        }
    }
    private(set) var lastDiagnostic: String?
    private(set) var desktopActiveTurnCount: Int = 0
    private(set) var desktopDebugSummary: String?
    private(set) var archivedThreadTombstonesByID: [String: Date] = [:]
    private var threadOrderingCache = ThreadOrderingCache()

    var recentThreads: [ThreadRow] {
        if let cached = threadOrderingCache.recentThreads {
            return cached
        }

        let sortedThreads = threadsByID.values.sorted { lhs, rhs in
            if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }

            return lhs.activityUpdatedAt > rhs.activityUpdatedAt
        }
        threadOrderingCache.recentThreads = sortedThreads
        return sortedThreads
    }

    var visibleRecentThreads: [ThreadRow] {
        if let cached = threadOrderingCache.visibleRecentThreads {
            return cached
        }

        let visibleThreads = recentThreads.filter { !$0.isSubagent }
        threadOrderingCache.visibleRecentThreads = visibleThreads
        return visibleThreads
    }

    func projectSections(
        using catalog: CodexDesktopProjectCatalog,
        maxProjects: Int = .max,
        maxThreads: Int = .max
    ) -> [ProjectSection] {
        let allSections = buildProjectSections(from: visibleRecentThreads, using: catalog)
        guard maxProjects != .max || maxThreads != .max else {
            return allSections
        }

        return limitedProjectSections(allSections, maxProjects: maxProjects, maxThreads: maxThreads)
    }

    var overallStatus: OverallStatus {
        if connection == .connecting {
            return .connecting
        }

        let threads = recentThreads

        if threads.contains(where: {
            $0.presentationStatus == .waitingForUser
        }) {
            return .waitingForUser
        }

        if threads.contains(where: {
            $0.presentationStatus == .running
        }) {
            return .running
        }

        if desktopActiveTurnCount > 0 {
            return .running
        }

        if connection.isFailed {
            return .failed
        }

        if threads.contains(where: {
            $0.presentationStatus == .failed
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
            $0.presentationStatus == .running
        }.count
        let runningCount = max(runningThreadCount, desktopActiveTurnCount)
        let waitingCount = recentThreads.filter {
            $0.displayStatus == .waitingForInput
        }.count
        let approvalCount = recentThreads.filter {
            $0.displayStatus == .needsApproval
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
            if thread.presentationStatus == .waitingForUser { return shortThreadID(thread.id) }
            return nil
        }
        let approvalThreadIDs = recentThreads.compactMap { thread in
            if thread.pendingRequestKind == .approval { return shortThreadID(thread.id) }
            return nil
        }
        let runningThreadIDs = recentThreads.compactMap { thread in
            if thread.presentationStatus == .running { return shortThreadID(thread.id) }
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

    mutating func replaceRecentThreads(with threads: [CodexThread], omissionGraceCount: Int = 0) {
        let observedAt = Date()
        pruneArchivedThreadTombstones(observedAt: observedAt)
        var updatedThreads: [String: ThreadRow] = [:]

        for thread in threads {
            guard !isArchivedThreadTombstoned(thread.id, observedAt: observedAt) else {
                continue
            }

            var row = threadsByID[thread.id] ?? ThreadRow(thread: thread, isWatched: false)
            let previousStatus = row.displayStatus
            let previousUpdatedAt = row.updatedAt
            let incomingUpdatedAt = thread.updatedDate
            row.displayTitle = thread.displayTitle
            row.preview = thread.previewLine
            row.cwd = thread.cwd
            row.sessionPath = thread.path
            row.isSubagent = thread.isSubagent
            row.parentThreadID = thread.subagentParentThreadID
            row.agentNickname = thread.agentNickname

            let newStatus = ThreadStatus(threadStatus: thread.status)
            row.listedStatus = newStatus
            row.authoritativeListPresence = .listed
            row.authoritativeListOmissionCount = 0
            row.updatedAt = max(row.updatedAt, incomingUpdatedAt)
            row.statusUpdatedAt = max(row.statusUpdatedAt, incomingUpdatedAt)
            row.applyListedStatus(newStatus, observedAt: incomingUpdatedAt)

            if row.isWatched {
                row.activeTurnID = updatedActiveTurnID(
                    existing: row.activeTurnID,
                    status: row.displayStatus,
                    allowClearing: true
                )
            }

            synchronizeTerminalActivityFromAuthoritativeUpdate(
                row: &row,
                previousStatus: previousStatus,
                previousUpdatedAt: previousUpdatedAt,
                incomingUpdatedAt: incomingUpdatedAt
            )

            if row.lastTerminalActivityAt == nil,
               row.isWatched,
               row.activeTurnID == nil,
               shouldInferTerminalActivity(previous: previousStatus, current: row.displayStatus) {
                row.lastTerminalActivityAt = row.updatedAt
                row.hasInferredTerminalActivity = false
            }

            updatedThreads[thread.id] = row
        }

        for (threadID, row) in threadsByID where updatedThreads[threadID] == nil {
            guard Self.shouldRetainThreadOutsideAuthoritativeList(row) else {
                if row.authoritativeListPresence != .listed {
                    continue
                }

                let nextOmissionCount = row.authoritativeListOmissionCount + 1
                guard omissionGraceCount > 0,
                      nextOmissionCount <= omissionGraceCount else {
                    continue
                }

                var retainedRow = row
                retainedRow.authoritativeListOmissionCount = nextOmissionCount
                updatedThreads[threadID] = retainedRow
                continue
            }

            updatedThreads[threadID] = row
        }

        threadsByID = updatedThreads
    }

    mutating func markWatched(thread: CodexThread) {
        let observedAt = Date()
        pruneArchivedThreadTombstones(observedAt: observedAt)
        guard !isArchivedThreadTombstoned(thread.id, observedAt: observedAt) else {
            return
        }

        let existingRow = threadsByID[thread.id]
        var row = existingRow ?? ThreadRow(thread: thread, isWatched: true)
        let previousStatus = row.displayStatus
        let previousUpdatedAt = row.updatedAt
        let incomingUpdatedAt = thread.updatedDate
        row.displayTitle = thread.displayTitle
        row.preview = thread.previewLine
        row.cwd = thread.cwd
        row.sessionPath = thread.path
        row.isSubagent = thread.isSubagent
        row.parentThreadID = thread.subagentParentThreadID
        row.agentNickname = thread.agentNickname
        let newStatus = ThreadStatus(threadStatus: thread.status)
        if existingRow == nil {
            row.updatedAt = incomingUpdatedAt
        }
        row.statusUpdatedAt = max(row.statusUpdatedAt, incomingUpdatedAt)
        row.listedStatus = newStatus
        row.authoritativeListPresence = .listed
        row.authoritativeListOmissionCount = 0
        row.isWatched = true
        row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, incomingUpdatedAt)
        row.applyListedStatus(newStatus, observedAt: incomingUpdatedAt)
        row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.displayStatus, allowClearing: true)
        synchronizeTerminalActivityFromAuthoritativeUpdate(
            row: &row,
            previousStatus: previousStatus,
            previousUpdatedAt: previousUpdatedAt,
            incomingUpdatedAt: incomingUpdatedAt
        )
        if row.lastTerminalActivityAt == nil,
           row.activeTurnID == nil,
           isUnreadEligibleTerminalStatus(row.displayStatus) {
            row.lastTerminalActivityAt = row.updatedAt
            row.hasInferredTerminalActivity = false
        }
        threadsByID[thread.id] = row
    }

    mutating func mergeRecentThread(_ thread: CodexThread) {
        let observedAt = Date()
        pruneArchivedThreadTombstones(observedAt: observedAt)
        guard !isArchivedThreadTombstoned(thread.id, observedAt: observedAt) else {
            return
        }

        let existingRow = threadsByID[thread.id]
        var row = existingRow ?? ThreadRow(thread: thread, isWatched: false)
        let previousStatus = row.displayStatus
        let previousUpdatedAt = row.updatedAt
        let incomingUpdatedAt = thread.updatedDate
        row.displayTitle = thread.displayTitle
        row.preview = thread.previewLine
        row.cwd = thread.cwd
        row.sessionPath = thread.path
        row.isSubagent = thread.isSubagent
        row.parentThreadID = thread.subagentParentThreadID
        row.agentNickname = thread.agentNickname

        let newStatus = ThreadStatus(threadStatus: thread.status)
        row.listedStatus = newStatus
        if existingRow == nil || row.authoritativeListPresence == .pendingInclusion {
            row.authoritativeListPresence = .pendingInclusion
        }
        row.authoritativeListOmissionCount = 0
        row.updatedAt = max(row.updatedAt, incomingUpdatedAt)
        row.statusUpdatedAt = max(row.statusUpdatedAt, incomingUpdatedAt)
        row.applyListedStatus(newStatus, observedAt: incomingUpdatedAt)

        if row.isWatched {
            row.activeTurnID = updatedActiveTurnID(
                existing: row.activeTurnID,
                status: row.displayStatus,
                allowClearing: true
            )
        }

        synchronizeTerminalActivityFromAuthoritativeUpdate(
            row: &row,
            previousStatus: previousStatus,
            previousUpdatedAt: previousUpdatedAt,
            incomingUpdatedAt: incomingUpdatedAt
        )

        if row.lastTerminalActivityAt == nil,
           row.isWatched,
           row.activeTurnID == nil,
           shouldInferTerminalActivity(previous: previousStatus, current: row.displayStatus) {
            row.lastTerminalActivityAt = row.updatedAt
            row.hasInferredTerminalActivity = false
        }

        threadsByID[thread.id] = row
    }

    mutating func prunePendingAuthoritativeThreads(keeping threadIDs: Set<String>) {
        guard !threadsByID.isEmpty else { return }

        let expiredThreadIDs = threadsByID.compactMap { entry -> String? in
            let (threadID, row) = entry
            guard row.authoritativeListPresence == .pendingInclusion,
                  !threadIDs.contains(threadID),
                  !Self.shouldRetainThreadOutsidePendingWindow(row) else {
                return nil
            }

            return threadID
        }

        for threadID in expiredThreadIDs {
            threadsByID.removeValue(forKey: threadID)
        }
    }

    mutating func markUnwatched(threadIDs: Set<String>) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            guard var row = threadsByID[threadID] else { continue }
            row.isWatched = false
            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = .none
            row.activeTurnID = nil
            row.status = row.listedStatus
            threadsByID[threadID] = row
        }
    }

    @discardableResult
    mutating func removeThreads(threadIDs: Set<String>) -> Set<String> {
        guard !threadIDs.isEmpty, !threadsByID.isEmpty else { return [] }

        var removedThreadIDs = threadIDs
        var discoveredDescendant = true

        while discoveredDescendant {
            discoveredDescendant = false

            for row in threadsByID.values {
                guard !removedThreadIDs.contains(row.id),
                      let parentThreadID = row.parentThreadID,
                      removedThreadIDs.contains(parentThreadID) else {
                    continue
                }

                removedThreadIDs.insert(row.id)
                discoveredDescendant = true
            }
        }

        for threadID in removedThreadIDs {
            threadsByID.removeValue(forKey: threadID)
        }

        return removedThreadIDs
    }

    mutating func archiveThreads(threadIDs: Set<String>, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        pruneArchivedThreadTombstones(observedAt: observedAt)
        let removedThreadIDs = removeThreads(threadIDs: threadIDs).union(threadIDs)
        for threadID in removedThreadIDs {
            archivedThreadTombstonesByID[threadID] = observedAt
        }
    }

    mutating func clearLiveRuntimeState() {
        desktopActiveTurnCount = 0
        desktopDebugSummary = nil

        for threadID in threadsByID.keys.sorted() {
            guard var row = threadsByID[threadID] else {
                continue
            }

            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = .none
            row.activeTurnID = nil
            row.status = row.listedStatus
            row.lastRuntimeEventAt = nil

            if row.hasInferredTerminalActivity {
                if isUnreadEligibleTerminalStatus(row.listedStatus) {
                    row.lastTerminalActivityAt = row.updatedAt
                } else {
                    row.lastTerminalActivityAt = nil
                }
                row.hasInferredTerminalActivity = false
            }

            threadsByID[threadID] = row
        }
    }

    mutating func apply(desktopSnapshot: CodexDesktopRuntimeSnapshot, observedAt: Date = Date()) {
        pruneArchivedThreadTombstones(observedAt: observedAt)
        desktopActiveTurnCount = max(0, desktopSnapshot.activeTurnCount)
        desktopDebugSummary = desktopSnapshot.debugSummary
        reconcileRunningThreads(
            runningThreadIDs: desktopSnapshot.runningThreadIDs,
            activeTurnCount: desktopSnapshot.activeTurnCount,
            observedAt: observedAt
        )
        reconcilePendingThreads(
            pendingThreadIDs: desktopSnapshot.waitingForInputThreadIDs.union(desktopSnapshot.approvalThreadIDs),
            runningThreadIDs: desktopSnapshot.runningThreadIDs,
            observedAt: observedAt
        )
        reconcileFailedThreads(
            failedThreadIDs: Set(desktopSnapshot.failedThreads.keys),
            observedAt: observedAt
        )
        overlayFailedThreads(desktopSnapshot.failedThreads)
        overlayPendingThreads(desktopSnapshot.waitingForInputThreadIDs, status: .waitingForInput, observedAt: observedAt)
        overlayPendingThreads(desktopSnapshot.approvalThreadIDs, status: .needsApproval, observedAt: observedAt)
        overlayRunningThreads(desktopSnapshot.runningThreadIDs, observedAt: observedAt)
    }

    mutating func apply(connectedDesktopSnapshot desktopSnapshot: CodexDesktopRuntimeSnapshot, observedAt: Date = Date()) {
        pruneArchivedThreadTombstones(observedAt: observedAt)
        let trustedRunningThreadIDs = trustedConnectedDesktopRunningThreadIDs(
            desktopSnapshot.runningThreadIDs,
            observedAt: observedAt
        )
        reconcileRunningThreads(
            runningThreadIDs: trustedRunningThreadIDs,
            activeTurnCount: desktopSnapshot.activeTurnCount,
            observedAt: observedAt
        )
        desktopActiveTurnCount = connectedDesktopActiveTurnCount(
            activeTurnCount: desktopSnapshot.activeTurnCount,
            trustedRunningThreadIDs: trustedRunningThreadIDs
        )
        desktopDebugSummary = desktopSnapshot.debugSummary
        overlayFailedThreads(desktopSnapshot.failedThreads)
        overlayPendingThreads(desktopSnapshot.waitingForInputThreadIDs, status: .waitingForInput, observedAt: observedAt)
        overlayPendingThreads(desktopSnapshot.approvalThreadIDs, status: .needsApproval, observedAt: observedAt)
        overlayRunningThreads(trustedRunningThreadIDs, observedAt: observedAt)
    }

    mutating func apply(desktopTurnStarts startedAtByThreadID: [String: Date]) {
        guard !startedAtByThreadID.isEmpty else { return }

        for threadID in startedAtByThreadID.keys.sorted() {
            guard let startedAt = startedAtByThreadID[threadID] else {
                continue
            }

            updateThread(threadID: threadID) { row in
                guard Self.shouldAcceptDesktopTurnStart(for: row, startedAt: startedAt) else {
                    return
                }

                row.activeTurnID = row.activeTurnID ?? Self.inferredActiveTurnID
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, startedAt)
                row.statusUpdatedAt = max(row.statusUpdatedAt, startedAt)

                guard row.pendingRequestKind == nil else {
                    return
                }

                row.runtimePhase = .running
                row.status = .running
            }
        }
    }

    mutating func apply(desktopCompletionHints completedAtByThreadID: [String: Date]) {
        guard !completedAtByThreadID.isEmpty else { return }

        var clearedRunningState = false

        for threadID in completedAtByThreadID.keys.sorted() {
            guard let completedAt = completedAtByThreadID[threadID],
                  var row = threadsByID[threadID],
                  Self.shouldAcceptDesktopCompletionHint(for: row, completedAt: completedAt)
            else {
                continue
            }

            let previousStatus = row.displayStatus
            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = .none
            row.activeTurnID = nil
            row.status = Self.terminalStatusAfterDesktopCompletion(for: row)
            row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, completedAt)
            row.statusUpdatedAt = max(row.statusUpdatedAt, completedAt)
            row.lastTerminalActivityAt = max(row.lastTerminalActivityAt ?? .distantPast, completedAt)
            row.hasInferredTerminalActivity = false
            threadsByID[threadID] = row

            if previousStatus != row.displayStatus {
                clearedRunningState = true
                recordDiagnostic("cleared stale running thread=\(shortThreadID(threadID)) from=\(previousStatus.displayName) to=\(row.displayStatus.displayName) via desktop completion")
            }
        }

        if clearedRunningState && !recentThreads.contains(where: { $0.presentationStatus == .running }) {
            desktopActiveTurnCount = 0
        }
    }

    private mutating func reconcileRunningThreads(
        runningThreadIDs: Set<String>,
        activeTurnCount: Int,
        observedAt: Date = Date()
    ) {
        for threadID in threadsByID.keys.sorted() {
            guard var row = threadsByID[threadID],
                  row.presentationStatus == .running,
                  Self.shouldAcceptDesktopRunningSync(
                    for: row,
                    activeTurnCount: activeTurnCount,
                    observedAt: observedAt
                  ),
                  !runningThreadIDs.contains(threadID)
            else {
                continue
            }

            let previousStatus = row.displayStatus
            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = .none
            row.activeTurnID = nil
            row.status = row.listedStatus
            row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
            row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            threadsByID[threadID] = row

            guard row.displayStatus != previousStatus else { continue }
            recordDiagnostic("cleared stale running thread=\(shortThreadID(threadID)) from=\(previousStatus.displayName) to=\(row.displayStatus.displayName) via desktop snapshot")
        }
    }

    private static func shouldAcceptDesktopRunningSync(
        for row: ThreadRow,
        activeTurnCount: Int,
        observedAt: Date
    ) -> Bool {
        guard observedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        if row.activeTurnID != nil {
            return activeTurnCount <= 0
                && observedAt.timeIntervalSince(row.lastRuntimeEventAt ?? .distantPast) >= desktopActiveTurnSafetyTimeout
        }

        if !row.isWatched {
            return true
        }

        guard row.listedStatus != .running else {
            return false
        }

        // Give live notifications and desktop files a moment to converge before downgrading.
        return observedAt.timeIntervalSince(row.lastRuntimeEventAt ?? .distantPast) >= watchedRunningReconciliationGraceInterval
    }

    private mutating func reconcilePendingThreads(
        pendingThreadIDs: Set<String>,
        runningThreadIDs: Set<String>,
        observedAt: Date = Date()
    ) {
        for threadID in threadsByID.keys.sorted() {
            guard var row = threadsByID[threadID], row.pendingRequestKind != nil, !pendingThreadIDs.contains(threadID) else {
                continue
            }

            guard Self.shouldAcceptDesktopPendingReconciliation(for: row, observedAt: observedAt) else {
                continue
            }

            let previousStatus = row.displayStatus
            if runningThreadIDs.contains(threadID) {
                row.pendingRequestKind = nil
                row.pendingRequestReason = nil
                row.runtimePhase = .running
                row.status = .running
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
            } else {
                row.status = row.listedStatus
                row.pendingRequestKind = nil
                row.pendingRequestReason = nil
                row.runtimePhase = .none
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
            }
            row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)

            guard row.displayStatus != previousStatus else { continue }
            threadsByID[threadID] = row
            recordDiagnostic("cleared stale pending thread=\(shortThreadID(threadID)) from=\(previousStatus.displayName) to=\(row.displayStatus.displayName) via desktop snapshot")
        }
    }

    private mutating func reconcileFailedThreads(
        failedThreadIDs: Set<String>,
        observedAt: Date = Date()
    ) {
        for threadID in threadsByID.keys.sorted() {
            guard var row = threadsByID[threadID],
                  row.presentationStatus == .failed,
                  !failedThreadIDs.contains(threadID),
                  Self.shouldAcceptDesktopFailedSync(for: row, observedAt: observedAt)
            else {
                continue
            }

            let previousStatus = row.displayStatus
            row.status = row.listedStatus
            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = .none
            row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
            row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            threadsByID[threadID] = row

            guard row.displayStatus != previousStatus else { continue }
            recordDiagnostic("cleared stale failed thread=\(shortThreadID(threadID)) from=\(previousStatus.displayName) to=\(row.displayStatus.displayName) via desktop snapshot")
        }
    }

    private static func shouldAcceptDesktopFailedSync(for row: ThreadRow, observedAt: Date) -> Bool {
        guard observedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        if case .failed = row.listedStatus {
            return false
        }

        if row.isWatched {
            return observedAt.timeIntervalSince(row.lastRuntimeEventAt ?? .distantPast) >= watchedFailedReconciliationGraceInterval
        }

        return true
    }

    private mutating func overlayPendingThreads(_ threadIDs: Set<String>, status: ThreadStatus, observedAt: Date = Date()) {
        guard !threadIDs.isEmpty else { return }

        for threadID in threadIDs {
            updateThread(threadID: threadID) { row in
                guard Self.shouldAcceptDesktopPendingOverlay(for: row, observedAt: observedAt) else {
                    return
                }

                row.status = status
                row.pendingRequestKind = status == .needsApproval ? .approval : .userInput
                row.pendingRequestReason = nil
                row.runtimePhase = .none
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
                row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            }
        }
    }

    private static func shouldAcceptDesktopPendingOverlay(for row: ThreadRow, observedAt: Date) -> Bool {
        guard observedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        return shouldAcceptDesktopPendingOverlaySync(for: row)
    }

    private static func shouldAcceptDesktopPendingOverlaySync(for row: ThreadRow) -> Bool {
        guard row.isWatched else {
            return true
        }

        return row.sessionPath != nil
    }

    private static func shouldAcceptDesktopPendingReconciliation(for row: ThreadRow, observedAt: Date) -> Bool {
        guard observedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        guard row.isWatched else {
            return true
        }

        if row.sessionPath != nil {
            return true
        }

        guard !row.listedStatus.isPending else {
            return false
        }

        // When a live resolution event is missed, desktop snapshots should eventually
        // clear stale pending state even if the watched row lacks a session file path.
        return observedAt.timeIntervalSince(row.lastRuntimeEventAt ?? .distantPast) >= watchedPendingReconciliationGraceInterval
    }

    private mutating func overlayFailedThreads(_ failures: [String: CodexDesktopRuntimeSnapshot.FailedThreadState]) {
        guard !failures.isEmpty else { return }

        for (threadID, failure) in failures {
            updateThread(threadID: threadID) { row in
                guard !row.isWatched else {
                    return
                }

                guard row.updatedAt <= failure.loggedAt else {
                    return
                }

                row.pendingRequestKind = nil
                row.pendingRequestReason = nil
                row.runtimePhase = .none
                row.status = .failed(message: failure.message)
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, failure.loggedAt)
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
                guard Self.shouldAcceptDesktopRunningOverlay(for: row, observedAt: observedAt) else {
                    return
                }

                row.pendingRequestKind = nil
                row.pendingRequestReason = nil
                row.runtimePhase = .running
                row.status = .running
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
                row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            }
        }
    }

    private static func shouldAcceptDesktopRunningOverlay(for row: ThreadRow, observedAt: Date) -> Bool {
        guard observedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        if !row.isWatched {
            return true
        }

        guard row.activeTurnID != nil || row.lastTerminalActivityAt == nil else {
            return false
        }

        guard !hasAuthoritativeTerminalActivity(row) else {
            return false
        }

        switch row.presentationStatus {
        case .waitingForUser, .running:
            return false
        case .idle, .notLoaded, .failed:
            return true
        }
    }

    private static func shouldAcceptDesktopCompletionHint(for row: ThreadRow, completedAt: Date) -> Bool {
        let lastTerminalActivityAt = row.lastTerminalActivityAt ?? .distantPast
        guard completedAt > lastTerminalActivityAt || row.presentationStatus == .running else {
            return false
        }

        let lastRuntimeEventAt = row.lastRuntimeEventAt ?? .distantPast
        if completedAt.addingTimeInterval(completionHintClockTolerance) >= lastRuntimeEventAt {
            return true
        }

        return row.runtimePhase == .running
            && row.activeTurnID == nil
            && completedAt >= lastTerminalActivityAt
    }

    private static func shouldAcceptDesktopTurnStart(for row: ThreadRow, startedAt: Date) -> Bool {
        guard startedAt >= (row.lastRuntimeEventAt ?? .distantPast) else {
            return false
        }

        if let lastTerminalActivityAt = row.lastTerminalActivityAt,
           lastTerminalActivityAt >= startedAt {
            return false
        }

        return true
    }

    private static func terminalStatusAfterDesktopCompletion(for row: ThreadRow) -> ThreadStatus {
        switch row.listedStatus {
        case .idle, .failed:
            return row.listedStatus
        case .notLoaded, .waitingForInput, .running, .needsApproval:
            if case let .failed(message) = row.status {
                return .failed(message: message)
            }

            return .idle
        }
    }

    mutating func apply(notification: NotificationEvent) {
        switch notification {
        case let .threadStarted(notification):
            let notificationObservedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.thread.id, observedAt: notificationObservedAt) else {
                return
            }

            let existingRow = threadsByID[notification.thread.id]
            var row = existingRow ?? ThreadRow(thread: notification.thread, isWatched: true)
            let previousStatus = row.displayStatus
            let observedAt = notification.thread.updatedDate
            row.displayTitle = notification.thread.displayTitle
            row.preview = notification.thread.previewLine
            row.cwd = notification.thread.cwd
            row.sessionPath = notification.thread.path
            row.isSubagent = notification.thread.isSubagent
            row.parentThreadID = notification.thread.subagentParentThreadID
            row.agentNickname = notification.thread.agentNickname
            row.updatedAt = max(row.updatedAt, observedAt)
            row.statusUpdatedAt = max(row.statusUpdatedAt, observedAt)
            let runtimeStatus = ThreadStatus(threadStatus: notification.thread.status)
            row.listedStatus = runtimeStatus
            if existingRow == nil || row.authoritativeListPresence == .pendingInclusion {
                row.authoritativeListPresence = .pendingInclusion
            }
            row.authoritativeListOmissionCount = 0
            row.isWatched = true
            row.applyRuntimeStatus(runtimeStatus, observedAt: observedAt)
            row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.displayStatus, allowClearing: false)
            threadsByID[notification.thread.id] = row
            recordPendingResolution(threadID: notification.thread.id, previous: previousStatus, current: row.displayStatus, source: "thread/started")
        case let .threadStatusChanged(notification):
            let observedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.threadId, observedAt: observedAt) else {
                return
            }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.displayStatus
            row.isWatched = true
            row.authoritativeListOmissionCount = 0
            let runtimeStatus = ThreadStatus(threadStatus: notification.status)
            row.applyRuntimeStatus(runtimeStatus, observedAt: observedAt)
            row.statusUpdatedAt = observedAt
            row.activeTurnID = updatedActiveTurnID(existing: row.activeTurnID, status: row.displayStatus, allowClearing: false)
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "thread/status/changed")
        case let .threadArchived(notification):
            archiveThreads(threadIDs: [notification.threadId])
        case let .threadUnarchived(notification):
            archivedThreadTombstonesByID.removeValue(forKey: notification.threadId)
        case let .threadNameUpdated(notification):
            guard var row = threadsByID[notification.threadId],
                  let normalizedName = Self.normalizedThreadDisplayTitle(notification.name)
            else {
                return
            }

            row.displayTitle = normalizedName
            threadsByID[notification.threadId] = row
        case let .turnStarted(notification):
            let observedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.threadId, observedAt: observedAt) else {
                return
            }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.displayStatus
            row.isWatched = true
            row.authoritativeListOmissionCount = 0
            row.activeTurnID = notification.turn.id
            row.statusUpdatedAt = observedAt
            row.applyRuntimeStatus(.running, observedAt: observedAt)
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "turn/started")
        case let .itemStarted(notification):
            let observedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.threadId, observedAt: observedAt) else {
                return
            }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.displayStatus
            row.isWatched = true
            row.authoritativeListOmissionCount = 0
            row.activeTurnID = notification.turnId
            row.statusUpdatedAt = observedAt
            row.applyRuntimeStatus(.running, observedAt: observedAt)
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "item/started")
        case let .turnCompleted(notification):
            let observedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.threadId, observedAt: observedAt) else {
                return
            }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.displayStatus
            row.isWatched = true
            row.authoritativeListOmissionCount = 0
            row.activeTurnID = nil
            row.statusUpdatedAt = observedAt
            row.lastTerminalActivityAt = observedAt
            row.hasInferredTerminalActivity = true

            let currentStatus: ThreadStatus
            switch notification.turn.status {
            case .completed, .interrupted:
                currentStatus = .idle
            case .failed:
                currentStatus = .failed(message: notification.turn.error?.message)
            case .inProgress:
                currentStatus = .running
            }
            row.applyRuntimeStatus(currentStatus, observedAt: observedAt)

            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "turn/completed")
        case let .error(notification):
            guard !notification.willRetry else { return }

            let observedAt = Date()
            guard !shouldIgnoreArchivedThreadEvent(threadID: notification.threadId, observedAt: observedAt) else {
                return
            }

            var row = threadsByID[notification.threadId] ?? defaultThreadRow(threadID: notification.threadId)
            let previousStatus = row.displayStatus
            row.isWatched = true
            row.authoritativeListOmissionCount = 0
            row.activeTurnID = nil
            row.statusUpdatedAt = observedAt
            row.lastTerminalActivityAt = observedAt
            row.hasInferredTerminalActivity = true
            row.applyRuntimeStatus(.failed(message: notification.error.message), observedAt: observedAt)
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "error")
        case let .serverRequestResolved(notification):
            guard var row = threadsByID[notification.threadId], row.pendingRequestKind != nil else {
                return
            }

            let previousStatus = row.displayStatus
            let observedAt = Date()
            row.pendingRequestKind = nil
            row.pendingRequestReason = nil
            row.runtimePhase = (row.activeTurnID != nil || row.status == .running) ? .running : .none
            row.status = row.runtimePhase == .running ? .running : row.listedStatus
            row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
            row.statusUpdatedAt = observedAt
            threadsByID[notification.threadId] = row
            recordPendingResolution(threadID: notification.threadId, previous: previousStatus, current: row.displayStatus, source: "serverRequest/resolved")
        }
    }

    mutating func apply(serverRequest: ServerRequestEvent) {
        switch serverRequest {
        case let .toolUserInput(request):
            updateThread(threadID: request.threadId) { row in
                let observedAt = Date()
                row.isWatched = true
                row.authoritativeListOmissionCount = 0
                row.activeTurnID = request.turnId
                row.status = .waitingForInput
                row.pendingRequestKind = .userInput
                row.pendingRequestReason = nil
                row.runtimePhase = .none
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
                row.statusUpdatedAt = observedAt
            }
        case let .approval(request):
            updateThread(threadID: request.threadId) { row in
                let observedAt = Date()
                row.isWatched = true
                row.authoritativeListOmissionCount = 0
                row.activeTurnID = request.turnId
                row.status = .needsApproval
                row.pendingRequestKind = .approval
                row.pendingRequestReason = request.reason
                row.runtimePhase = .none
                row.lastRuntimeEventAt = max(row.lastRuntimeEventAt ?? .distantPast, observedAt)
                row.statusUpdatedAt = observedAt
            }
        }
    }

    func notificationBody(forThreadID threadID: String, fallback: String) -> String {
        guard let thread = threadsByID[threadID] else { return fallback }
        return "\(thread.displayTitle): \(fallback)"
    }

    private mutating func recordPendingResolution(threadID: String, previous: ThreadStatus, current: ThreadStatus, source: String) {
        guard previous.isPending, !current.isPending else { return }
        recordDiagnostic("cleared pending thread=\(shortThreadID(threadID)) from=\(previous.displayName) to=\(current.displayName) via \(source)")
    }

    private func connectedDesktopActiveTurnCount(
        activeTurnCount: Int,
        trustedRunningThreadIDs: Set<String>
    ) -> Int {
        let activeTurnCount = max(0, activeTurnCount)
        guard activeTurnCount > 0 else { return 0 }

        if !trustedRunningThreadIDs.isEmpty
            || recentThreads.contains(where: { $0.presentationStatus == .running }) {
            return activeTurnCount
        }

        return 0
    }

    private func trustedConnectedDesktopRunningThreadIDs(
        _ runningThreadIDs: Set<String>,
        observedAt: Date
    ) -> Set<String> {
        Set(runningThreadIDs.filter { threadID in
            guard !isArchivedThreadTombstoned(threadID, observedAt: observedAt) else {
                return false
            }

            guard let row = threadsByID[threadID] else {
                return true
            }

            return Self.shouldTrustConnectedDesktopRunningEvidence(for: row, observedAt: observedAt)
        })
    }

    private static func shouldTrustConnectedDesktopRunningEvidence(for row: ThreadRow, observedAt: Date) -> Bool {
        guard row.isWatched else {
            return true
        }

        if row.presentationStatus == .running {
            return true
        }

        if hasAuthoritativeTerminalActivity(row) {
            return false
        }

        return shouldAcceptDesktopRunningOverlay(for: row, observedAt: observedAt)
    }

    private static func hasAuthoritativeTerminalActivity(_ row: ThreadRow) -> Bool {
        guard let lastTerminalActivityAt = row.lastTerminalActivityAt else {
            return false
        }

        return lastTerminalActivityAt >= (row.lastRuntimeEventAt ?? .distantPast)
    }

    private mutating func shouldIgnoreArchivedThreadEvent(threadID: String, observedAt: Date) -> Bool {
        pruneArchivedThreadTombstones(observedAt: observedAt)
        return isArchivedThreadTombstoned(threadID, observedAt: observedAt)
    }

    private mutating func pruneArchivedThreadTombstones(observedAt: Date) {
        archivedThreadTombstonesByID = archivedThreadTombstonesByID.filter { _, archivedAt in
            observedAt.timeIntervalSince(archivedAt) < Self.archivedThreadTombstoneTTL
        }
    }

    private func isArchivedThreadTombstoned(_ threadID: String, observedAt: Date) -> Bool {
        guard let archivedAt = archivedThreadTombstonesByID[threadID] else {
            return false
        }

        return observedAt.timeIntervalSince(archivedAt) < Self.archivedThreadTombstoneTTL
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

    private static func normalizedThreadDisplayTitle(_ title: String?) -> String? {
        guard let title else { return nil }

        let normalizedTitle = title
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        guard let normalizedTitle else {
            return nil
        }

        return String(normalizedTitle)
    }

    private func defaultThreadRow(threadID: String) -> ThreadRow {
        ThreadRow(
            id: threadID,
            displayTitle: threadID,
            preview: threadID,
            cwd: "",
            sessionPath: nil,
            isSubagent: false,
            parentThreadID: nil,
            status: .notLoaded,
            listedStatus: .notLoaded,
            updatedAt: .distantPast,
            statusUpdatedAt: .distantPast,
            isWatched: false,
            activeTurnID: nil,
            lastTerminalActivityAt: nil,
            hasInferredTerminalActivity: false
        )
    }

    private mutating func updateThread(threadID: String, update: (inout ThreadRow) -> Void) {
        let observedAt = Date()
        pruneArchivedThreadTombstones(observedAt: observedAt)
        guard !isArchivedThreadTombstoned(threadID, observedAt: observedAt) else {
            return
        }

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
            let project = catalog.project(forThreadID: thread.id, cwd: thread.cwd)
            if var bucket = buckets[project.id] {
                if thread.activityUpdatedAt > bucket.latestUpdatedAt {
                    bucket.latestUpdatedAt = thread.activityUpdatedAt
                }
                bucket.threads.append(thread)
                buckets[project.id] = bucket
            } else {
                buckets[project.id] = Bucket(
                    id: project.id,
                    displayName: project.displayName,
                    latestUpdatedAt: thread.activityUpdatedAt,
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
                    threads: bucket.threads.sorted(by: Self.isNewerThread)
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

        let priorityProjectIDs = Set(
            sections.compactMap { section in
                section.threads.contains(where: Self.isPriorityVisibleThread) ? section.id : nil
            }
        )
        let limitedProjectIDs = Set(
            sections
                .filter { priorityProjectIDs.contains($0.id) }
                .map(\.id)
                + sections
                    .filter { !priorityProjectIDs.contains($0.id) }
                    .prefix(maxProjectsExcludingPriority(maxProjects: maxProjects, priorityProjectIDs: priorityProjectIDs))
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

        let priorityThreads = limitedSections
            .flatMap(\.threads)
            .filter(Self.isPriorityVisibleThread)
            .sorted(by: Self.isHigherPriorityThread)

        for thread in priorityThreads {
            guard visibleThreadCount < maxThreads else { break }

            let projectID = threadProjectIDs[thread.id]
            guard let projectID else { continue }

            visibleThreadsByProject[projectID, default: []].append(thread)
            visibleThreadIDs.insert(thread.id)
            visibleThreadCount += 1
        }

        for section in limitedSections {
            guard visibleThreadCount < maxThreads else { break }
            guard let thread = section.threads.first(where: { !visibleThreadIDs.contains($0.id) }) else {
                continue
            }

            visibleThreadsByProject[section.id, default: []].append(thread)
            visibleThreadIDs.insert(thread.id)
            visibleThreadCount += 1
        }

        let remainingThreads = limitedSections
            .flatMap(\.threads)
            .filter { !visibleThreadIDs.contains($0.id) }
            .sorted(by: Self.isHigherPriorityThread)

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
                threads: visibleThreads.sorted(by: Self.isHigherPriorityThread)
            )
        }
    }

    private static func isNewerThread(_ lhs: ThreadRow, _ rhs: ThreadRow) -> Bool {
        if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.activityUpdatedAt > rhs.activityUpdatedAt
    }

    private static func isHigherPriorityThread(_ lhs: ThreadRow, _ rhs: ThreadRow) -> Bool {
        let lhsRank = visibilityPriority(for: lhs)
        let rhsRank = visibilityPriority(for: rhs)

        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        return isNewerThread(lhs, rhs)
    }

    private static func isPriorityVisibleThread(_ thread: ThreadRow) -> Bool {
        visibilityPriority(for: thread) > 0
    }

    private static func visibilityPriority(for thread: ThreadRow) -> Int {
        switch thread.presentationStatus {
        case .waitingForUser:
            return 3
        case .running:
            return 2
        case .failed:
            return 1
        case .idle, .notLoaded:
            return 0
        }
    }

    private static func shouldRetainThreadOutsideAuthoritativeList(_ row: ThreadRow) -> Bool {
        row.authoritativeListPresence == .pendingInclusion
    }

    private static func shouldRetainThreadOutsidePendingWindow(_ row: ThreadRow) -> Bool {
        switch row.presentationStatus {
        case .waitingForUser, .running, .failed:
            return true
        case .idle, .notLoaded:
            return false
        }
    }

    private func maxProjectsExcludingPriority(maxProjects: Int, priorityProjectIDs: Set<String>) -> Int {
        guard maxProjects != .max else { return .max }
        return max(0, maxProjects - priorityProjectIDs.count)
    }

    private func synchronizeTerminalActivityFromAuthoritativeUpdate(
        row: inout ThreadRow,
        previousStatus: ThreadStatus,
        previousUpdatedAt: Date,
        incomingUpdatedAt: Date
    ) {
        guard row.isWatched, row.activeTurnID == nil, isUnreadEligibleTerminalStatus(row.displayStatus) else {
            return
        }

        if row.hasInferredTerminalActivity, incomingUpdatedAt > previousUpdatedAt {
            row.lastTerminalActivityAt = row.updatedAt
            row.hasInferredTerminalActivity = false
            return
        }

        if row.lastTerminalActivityAt == nil,
           shouldInferTerminalActivity(previous: previousStatus, current: row.displayStatus) {
            row.lastTerminalActivityAt = row.updatedAt
            row.hasInferredTerminalActivity = false
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
        let initialStatus = AppStateStore.ThreadStatus(threadStatus: thread.status)
        self.id = thread.id
        self.displayTitle = thread.displayTitle
        self.preview = thread.previewLine
        self.cwd = thread.cwd
        self.sessionPath = thread.path
        self.isSubagent = thread.isSubagent
        self.parentThreadID = thread.subagentParentThreadID
        self.agentNickname = thread.agentNickname
        self.status = initialStatus
        self.listedStatus = initialStatus
        self.updatedAt = thread.updatedDate
        self.statusUpdatedAt = thread.updatedDate
        self.isWatched = isWatched
        self.runtimePhase = initialStatus == .running ? .running : .none
        switch initialStatus {
        case .waitingForInput:
            self.pendingRequestKind = .userInput
        case .needsApproval:
            self.pendingRequestKind = .approval
        case .notLoaded, .idle, .running, .failed:
            self.pendingRequestKind = nil
        }
        self.pendingRequestReason = nil
        self.lastRuntimeEventAt = isWatched ? thread.updatedDate : nil
        self.activeTurnID = nil
        self.lastTerminalActivityAt = nil
        self.hasInferredTerminalActivity = false
    }

    mutating func applyListedStatus(_ newStatus: AppStateStore.ThreadStatus, observedAt: Date) {
        guard observedAt >= (lastRuntimeEventAt ?? .distantPast) else {
            return
        }

        switch newStatus {
        case .waitingForInput:
            status = .waitingForInput
            pendingRequestKind = .userInput
            pendingRequestReason = nil
            runtimePhase = .none
        case .needsApproval:
            status = .needsApproval
            pendingRequestKind = .approval
            runtimePhase = .none
        case .running:
            status = .running
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .running
        case .notLoaded, .idle, .failed:
            status = newStatus
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .none
            activeTurnID = nil
        }
    }

    mutating func applyRuntimeStatus(_ runtimeStatus: AppStateStore.ThreadStatus, observedAt: Date) {
        lastRuntimeEventAt = max(lastRuntimeEventAt ?? .distantPast, observedAt)
        statusUpdatedAt = max(statusUpdatedAt, observedAt)

        switch runtimeStatus {
        case .waitingForInput:
            status = .waitingForInput
            pendingRequestKind = .userInput
            pendingRequestReason = nil
            runtimePhase = .none
        case .needsApproval:
            status = .needsApproval
            pendingRequestKind = .approval
            runtimePhase = .none
        case .running:
            status = .running
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .running
        case .idle:
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .none
            status = .idle
            activeTurnID = nil
        case let .failed(message):
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .none
            status = .failed(message: message)
            activeTurnID = nil
        case .notLoaded:
            pendingRequestKind = nil
            pendingRequestReason = nil
            runtimePhase = .none
            status = .notLoaded
            activeTurnID = nil
        }
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
