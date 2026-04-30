import Foundation

protocol DesktopActivityLoading: Sendable {
    func load(candidateSessionContexts: [String: ThreadSessionContext], now: Date) async -> DesktopActivityUpdate
}

private extension AppStateStore.NotificationEvent {
    var unreadTrackingThreadID: String? {
        switch self {
        case let .threadStarted(notification):
            return notification.thread.id
        case let .turnStarted(notification):
            return notification.threadId
        case let .itemStarted(notification):
            return notification.threadId
        case let .turnCompleted(notification):
            return notification.threadId
        case let .error(notification):
            return notification.threadId
        case .threadStatusChanged,
             .threadArchived,
             .threadUnarchived,
             .threadNameUpdated,
             .serverRequestResolved:
            return nil
        }
    }
}

protocol RecentThreadListing: Sendable {
    func recentThreads(limit: Int) async throws -> [CodexThread]
}

protocol ThreadMetadataReading: Sendable {
    func threads(threadIDs: Set<String>) async throws -> [CodexThread]
    func archivedThreadIDs(threadIDs: Set<String>) async throws -> Set<String>
}

extension ThreadMetadataReading {
    func archivedThreadIDs(threadIDs: Set<String>) async throws -> Set<String> {
        []
    }
}

protocol ProjectCatalogLoading: Sendable {
    func loadProjectCatalog() async throws -> CodexDesktopProjectCatalog
}

extension DesktopActivityService: DesktopActivityLoading {}

actor DesktopStateThreadMetadataReader: ThreadMetadataReading {
    private let reader: CodexDesktopStateReader

    init(codexDirectoryURLProvider: @escaping @Sendable () -> URL) {
        reader = CodexDesktopStateReader(codexDirectoryURLProvider: codexDirectoryURLProvider)
    }

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        try reader.threads(threadIDs: threadIDs)
    }

    func archivedThreadIDs(threadIDs: Set<String>) async throws -> Set<String> {
        try reader.archivedThreadIDs(threadIDs: threadIDs)
    }
}

actor DesktopProjectCatalogLoader: ProjectCatalogLoading {
    private let reader: CodexDesktopProjectCatalogReader

    init(codexDirectoryURLProvider: @escaping @Sendable () -> URL) {
        reader = CodexDesktopProjectCatalogReader(codexDirectoryURLProvider: codexDirectoryURLProvider)
    }

    func loadProjectCatalog() async throws -> CodexDesktopProjectCatalog {
        try reader.load()
    }
}

actor AppServerRecentThreadListing: RecentThreadListing {
    private let client: CodexAppServerClient
    private let fetchPageLimit: Int

    init(client: CodexAppServerClient, fetchPageLimit: Int) {
        self.client = client
        self.fetchPageLimit = fetchPageLimit
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: String?

        repeat {
            let remaining = max(0, limit - threads.count)
            let response: ThreadListResponse = try await client.call(
                method: "thread/list",
                params: ThreadListParams(
                    cursor: cursor,
                    limit: remaining == 0 ? fetchPageLimit : min(fetchPageLimit, remaining),
                    sortKey: .updatedAt,
                    archived: false
                )
            )

            threads.append(contentsOf: response.data)
            cursor = response.nextCursor
        } while cursor != nil && threads.count < limit

        return Array(threads.prefix(limit))
    }
}

struct MenubarControllerConfiguration {
    let initialFetchLimit: Int
    let maxTrackedThreads: Int
    let projectLimit: Int
    let visibleThreadLimit: Int
    let authoritativeListOmissionGraceCount: Int
    let maxPendingDiscoveredThreads: Int
    let pendingDiscoveredThreadTTL: TimeInterval
    let threadReadMarkerRetentionSeconds: TimeInterval
}

struct MenubarControllerEffects: Equatable {
    var diagnostics: [String] = []
    var shouldRequestThreadRefresh = false
    var shouldRequestDesktopActivityRefresh = false
    var shouldRequestDesktopActivityAfterThreadRefresh = false
    var shouldBoostThreadDiscovery = false
}

struct MenubarThreadSnapshot: Equatable, Identifiable {
    let thread: AppStateStore.ThreadRow
    let hasUnreadContent: Bool

    var id: String {
        thread.id
    }
}

struct MenubarThreadGroupSnapshot: Equatable, Identifiable {
    let thread: MenubarThreadSnapshot
    let childThreads: [MenubarThreadSnapshot]

    var id: String {
        thread.id
    }
}

struct MenubarProjectSectionSnapshot: Equatable, Identifiable {
    let section: AppStateStore.ProjectSection
    let threads: [MenubarThreadSnapshot]
    let threadGroups: [MenubarThreadGroupSnapshot]
    let allThreads: [MenubarThreadSnapshot]

    init(
        section: AppStateStore.ProjectSection,
        threads: [MenubarThreadSnapshot],
        threadGroups: [MenubarThreadGroupSnapshot],
        allThreads: [MenubarThreadSnapshot]? = nil
    ) {
        self.section = section
        self.threads = threads
        self.threadGroups = threadGroups
        self.allThreads = allThreads ?? Self.uniqueThreadSnapshots(
            threads + threadGroups.flatMap(\.childThreads)
        )
    }

    var id: String {
        section.id
    }

    private static func uniqueThreadSnapshots(
        _ threadSnapshots: [MenubarThreadSnapshot]
    ) -> [MenubarThreadSnapshot] {
        var seenThreadIDs: Set<String> = []
        var uniqueThreadSnapshots: [MenubarThreadSnapshot] = []

        for threadSnapshot in threadSnapshots where seenThreadIDs.insert(threadSnapshot.id).inserted {
            uniqueThreadSnapshots.append(threadSnapshot)
        }

        return uniqueThreadSnapshots
    }
}

struct MenubarSnapshot: Equatable {
    let overallStatus: AppStateStore.OverallStatus
    let hasUnreadThreads: Bool
    let projectSections: [MenubarProjectSectionSnapshot]
    let menuSections: [ThreadMenuSection]
    let hasRecentThreads: Bool
    let isWatchLatestThreadEnabled: Bool
}

struct MenubarPreparedSnapshot: Equatable {
    let snapshot: MenubarSnapshot
    let didChangeReadMarkers: Bool
}

struct MenubarStatusSnapshot: Equatable {
    let overallStatus: AppStateStore.OverallStatus
    let hasUnreadThreads: Bool
}

@MainActor
final class MenubarController {
    private enum DesktopActivityScanPolicy {
        static let candidateLimit = 64
        static let recentRuntimeLookback: TimeInterval = 5 * 60
    }

    private let loadDesktopActivity: @Sendable ([String: ThreadSessionContext], Date) async -> DesktopActivityUpdate
    private let loadRecentThreads: @Sendable (Int) async throws -> [CodexThread]
    private let loadThreadsByID: (Set<String>) async throws -> [CodexThread]
    private let loadArchivedThreadIDs: (Set<String>) async throws -> Set<String>
    private let loadProjectCatalog: () async throws -> CodexDesktopProjectCatalog
    private let configuration: MenubarControllerConfiguration
    private let now: () -> Date

    private(set) var state = AppStateStore()
    private(set) var projectCatalog = CodexDesktopProjectCatalog.empty
    private(set) var threadReadMarkers: ThreadReadMarkerStore
    private(set) var pendingDiscoveredThreads: PendingDiscoveredThreadStore

    init(
        desktopActivityLoader: DesktopActivityLoading,
        recentThreadListing: RecentThreadListing,
        threadMetadataReader: ThreadMetadataReading,
        projectCatalogLoader: ProjectCatalogLoading,
        initialThreadReadMarkers: [String: TimeInterval] = [:],
        configuration: MenubarControllerConfiguration,
        now: @escaping () -> Date = Date.init
    ) {
        self.loadDesktopActivity = { candidateSessionContexts, now in
            await desktopActivityLoader.load(candidateSessionContexts: candidateSessionContexts, now: now)
        }
        self.loadRecentThreads = { limit in
            try await recentThreadListing.recentThreads(limit: limit)
        }
        self.loadThreadsByID = { threadIDs in
            try await threadMetadataReader.threads(threadIDs: threadIDs)
        }
        self.loadArchivedThreadIDs = { threadIDs in
            try await threadMetadataReader.archivedThreadIDs(threadIDs: threadIDs)
        }
        self.loadProjectCatalog = {
            try await projectCatalogLoader.loadProjectCatalog()
        }
        self.threadReadMarkers = ThreadReadMarkerStore(lastReadTerminalAtByThreadID: initialThreadReadMarkers)
        self.pendingDiscoveredThreads = PendingDiscoveredThreadStore(
            maxTrackedThreads: configuration.maxPendingDiscoveredThreads,
            ttl: configuration.pendingDiscoveredThreadTTL
        )
        self.configuration = configuration
        self.now = now
    }

    var connection: AppStateStore.ConnectionState {
        state.connection
    }

    var overallStatus: AppStateStore.OverallStatus {
        state.overallStatus
    }

    var recentThreads: [AppStateStore.ThreadRow] {
        state.recentThreads
    }

    var visibleRecentThreads: [AppStateStore.ThreadRow] {
        state.visibleRecentThreads
    }

    var hasUnreadThreads: Bool {
        state.recentThreads.contains { thread in
            threadReadMarkers.hasUnreadContent(
                threadID: thread.id,
                lastTerminalActivityAt: thread.lastTerminalActivityAt
            )
        }
    }

    func prepareStatusSnapshot(
        projectLimit: Int? = nil,
        visibleThreadLimit: Int? = nil
    ) -> MenubarStatusSnapshot {
        let effectiveProjectLimit = projectLimit ?? configuration.projectLimit
        let effectiveVisibleThreadLimit = visibleThreadLimit ?? configuration.visibleThreadLimit
        let snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: threadReadMarkers,
            projectLimit: effectiveProjectLimit,
            visibleThreadLimit: effectiveVisibleThreadLimit,
            now: now()
        )

        return MenubarStatusSnapshot(
            overallStatus: snapshot.overallStatus,
            hasUnreadThreads: snapshot.hasUnreadThreads
        )
    }

    var persistedThreadReadMarkers: [String: TimeInterval] {
        threadReadMarkers.lastReadTerminalAtByThreadID
    }

    func setConnection(_ connection: AppStateStore.ConnectionState) {
        state.setConnection(connection)
    }

    func recordDiagnostic(_ diagnostic: String) {
        state.recordDiagnostic(diagnostic)
    }

    func loadInitialThreads(
        projectLimit: Int? = nil,
        visibleThreadLimit: Int? = nil
    ) async throws {
        let effectiveProjectLimit = max(1, projectLimit ?? configuration.projectLimit)
        let effectiveVisibleThreadLimit = max(1, visibleThreadLimit ?? configuration.visibleThreadLimit)
        projectCatalog = (try? await loadProjectCatalog()) ?? .empty

        let threads = try await bootstrapRecentThreads(
            projectLimit: effectiveProjectLimit,
            visibleThreadLimit: effectiveVisibleThreadLimit
        )
        state.replaceRecentThreads(with: threads)
        synchronizePendingAuthoritativeThreads()
    }

    func refreshThreads() async throws -> MenubarControllerEffects {
        let threads = try await hydratedRecentThreads(limit: configuration.maxTrackedThreads)
        let effects = recordDiscoveredThreadRefreshResult(threads: threads)
        projectCatalog = (try? await loadProjectCatalog()) ?? .empty
        state.replaceRecentThreads(
            with: threads,
            omissionGraceCount: configuration.authoritativeListOmissionGraceCount
        )
        synchronizePendingAuthoritativeThreads()
        return effects
    }

    func pruneThreadsMissingFromDesktopState() async -> MenubarControllerEffects {
        let rowsByID = Dictionary(uniqueKeysWithValues: state.recentThreads.map { ($0.id, $0) })
        let pruneGraceCutoff = now().addingTimeInterval(-configuration.pendingDiscoveredThreadTTL)
        let pendingDiscoveryThreadIDs = pendingDiscoveredThreads.pendingThreadIDs
        let protectedPendingThreadIDs = Set(rowsByID.keys).intersection(pendingDiscoveryThreadIDs)
        let staleThreadIDs = Set(
            rowsByID.values
                .filter { $0.updatedAt <= pruneGraceCutoff }
                .map(\.id)
        )
        let listedThreadIDs = Set(
            rowsByID.values.compactMap { row in
                row.authoritativeListPresence == .listed ? row.id : nil
            }
        )
        let candidateThreadIDs = staleThreadIDs.union(listedThreadIDs)

        guard !candidateThreadIDs.isEmpty else {
            return MenubarControllerEffects()
        }

        do {
            let archivedThreadIDs = try await loadArchivedThreadIDs(candidateThreadIDs)
            let presentThreadIDs = Set(try await loadThreadsByID(candidateThreadIDs).map(\.id))
            let missingThreadIDs = staleThreadIDs
                .subtracting(presentThreadIDs)
                .subtracting(archivedThreadIDs)
                .subtracting(protectedPendingThreadIDs)
            let removedThreadIDs = archivedThreadIDs.union(missingThreadIDs)

            guard !removedThreadIDs.isEmpty else {
                return MenubarControllerEffects()
            }

            state.removeThreads(threadIDs: removedThreadIDs)
            let diagnostic = "desktop pruned archived=\(debugThreadIDs(archivedThreadIDs)) "
                + "missing=\(debugThreadIDs(missingThreadIDs))"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        } catch {
            let diagnostic = "desktop prune skipped: \(error.localizedDescription)"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        }
    }

    func refreshDesktopActivity() async -> MenubarControllerEffects {
        if let reloadedProjectCatalog = try? await loadProjectCatalog() {
            projectCatalog = reloadedProjectCatalog
        }

        let trackedThreads = state.recentThreads
        let activityObservedAt = now()
        let desktopActivityCandidateRows = prioritizedDesktopActivityCandidateRows(
            from: trackedThreads,
            observedAt: activityObservedAt
        )
        let trackedPendingThreadIDs = Set(
            trackedThreads.compactMap { row in
                row.authoritativeListPresence == .pendingInclusion ? row.id : nil
            }
        )
        let candidateSessionContexts = Dictionary(
            uniqueKeysWithValues: desktopActivityCandidateRows.map { row in
                (
                    row.id,
                    ThreadSessionContext(
                        path: row.sessionPath,
                        authoritativeUpdatedAt: row.updatedAt,
                        authoritativeStatusIsPending: row.listedStatus.isPending,
                        authoritativeStatusIsActive: row.presentationStatus == .running || row.activeTurnID != nil
                    )
                )
            }
        )
        let update = await loadDesktopActivity(candidateSessionContexts, activityObservedAt)
        let isConnected = state.connection.isConnected
        let recentThreadIDs = Set(trackedThreads.map(\.id))
        let attentionThreadIDs = Set(update.runtimeSnapshot?.waitingForInputThreadIDs ?? [])
            .union(update.runtimeSnapshot?.approvalThreadIDs ?? [])
            .union(Set(update.runtimeSnapshot?.failedThreads.keys.map { $0 } ?? []))
        let discoveredThreadIDs = ThreadActivityRefreshPlanner.discoveredThreadIDsNeedingRefresh(
            recentThreadIDs: recentThreadIDs,
            latestViewedAtByThreadID: update.latestTurnStartedAtByThreadID,
            recentActivityThreadIDs: update.runtimeSnapshot?.recentActivityThreadIDs ?? [],
            attentionThreadIDs: attentionThreadIDs,
            now: activityObservedAt
        )
        let newlyObservedThreadIDs = pendingDiscoveredThreads.observe(
            discoveredThreadIDs.union(trackedPendingThreadIDs),
            now: activityObservedAt
        )
        let newlyDiscoveredThreadIDs = newlyObservedThreadIDs.subtracting(trackedPendingThreadIDs)
        let unresolvedPendingThreadIDs = pendingDiscoveredThreads.pendingThreadIDs.subtracting(recentThreadIDs)
        let threadIDsToSeed = newlyDiscoveredThreadIDs.union(unresolvedPendingThreadIDs)
        synchronizePendingAuthoritativeThreads()

        var effects = MenubarControllerEffects()
        state.apply(desktopTurnStarts: update.latestTurnStartedAtByThreadID)

        if let runtimeSnapshot = update.runtimeSnapshot {
            if isConnected {
                let trackedRunningThreadIDs = Set(
                    trackedThreads
                        .filter { $0.presentationStatus == .running }
                        .map(\.id)
                )
                if runtimeSnapshot.activeTurnCount > 0,
                   trackedRunningThreadIDs.isEmpty {
                    effects.shouldRequestThreadRefresh = true
                    effects.shouldRequestDesktopActivityAfterThreadRefresh = runtimeSnapshot.runningThreadIDs.isEmpty

                    let diagnostic = "desktop hinted active turn while app-server stayed idle "
                        + "activeTurns=\(runtimeSnapshot.activeTurnCount) recent=\(trackedThreads.count)"
                    state.recordDiagnostic(diagnostic)
                    effects.diagnostics.append(diagnostic)
                }

                state.apply(connectedDesktopSnapshot: runtimeSnapshot, observedAt: activityObservedAt)
            } else {
                state.apply(desktopSnapshot: runtimeSnapshot, observedAt: activityObservedAt)

                if runtimeSnapshot.activeTurnCount > 0,
                   !state.recentThreads.contains(where: { $0.presentationStatus == .running }) {
                    effects.shouldRequestThreadRefresh = true
                    effects.shouldRequestDesktopActivityAfterThreadRefresh = runtimeSnapshot.runningThreadIDs.isEmpty

                    let diagnostic = "desktop observed active turn without tracked running thread "
                        + "activeTurns=\(runtimeSnapshot.activeTurnCount) recent=\(trackedThreads.count)"
                    state.recordDiagnostic(diagnostic)
                    effects.diagnostics.append(diagnostic)
                }
            }
        } else if let runtimeErrorMessage = update.runtimeErrorMessage {
            let diagnostic = "Desktop activity unavailable: \(runtimeErrorMessage)"
            state.recordDiagnostic(diagnostic)
            effects.diagnostics.append(diagnostic)
            effects.shouldRequestThreadRefresh = true
            effects.shouldBoostThreadDiscovery = true
        }

        let unarchivedThreadIDs = desktopUnarchiveHintThreadIDs(
            trackedThreads: trackedThreads,
            update: update
        )
        for threadID in unarchivedThreadIDs.sorted() {
            state.apply(notification: .threadUnarchived(ThreadUnarchivedNotification(threadId: threadID)))
        }

        if isConnected {
            let completionHintThreadIDs = Set(trackedThreads.compactMap { thread -> String? in
                guard let completedAt = update.latestTurnCompletedAtByThreadID[thread.id],
                      completedAt > (thread.lastTerminalActivityAt ?? .distantPast),
                      completedAt >= (thread.lastRuntimeEventAt ?? .distantPast) else {
                    return nil
                }

                return thread.id
            })
            if !completionHintThreadIDs.isEmpty {
                effects.shouldRequestThreadRefresh = true

                let diagnostic = "desktop completion hints requested authoritative refresh threads="
                    + debugThreadIDs(completionHintThreadIDs)
                state.recordDiagnostic(diagnostic)
                effects.diagnostics.append(diagnostic)
            }
        }
        let trackedCompletionHintThreadIDs = Set(update.latestTurnCompletedAtByThreadID.keys)
            .intersection(Set(state.recentThreads.map(\.id)))
        armUnreadTracking(for: trackedCompletionHintThreadIDs)
        state.apply(desktopCompletionHints: update.latestTurnCompletedAtByThreadID)

        let archivedThreadIDs = desktopArchiveHintThreadIDs(
            trackedThreads: trackedThreads,
            update: update
        )
        if !archivedThreadIDs.isEmpty {
            for threadID in archivedThreadIDs.sorted() {
                state.apply(notification: .threadArchived(ThreadArchivedNotification(threadId: threadID)))
            }

            let diagnostic = "desktop hinted archive threads=" + debugThreadIDs(archivedThreadIDs)
            state.recordDiagnostic(diagnostic)
            effects.diagnostics.append(diagnostic)
        }

        synchronizeThreadReadMarkers(from: update.latestViewedAtByThreadID)

        if !threadIDsToSeed.isEmpty {
            let seedEffects = await seedDiscoveredThreads(threadIDsToSeed)
            effects.diagnostics.append(contentsOf: seedEffects.diagnostics)
            effects.shouldRequestDesktopActivityRefresh = effects.shouldRequestDesktopActivityRefresh
                || seedEffects.shouldRequestDesktopActivityRefresh
            effects.shouldRequestThreadRefresh = effects.shouldRequestThreadRefresh
                || !newlyDiscoveredThreadIDs.isEmpty
            effects.shouldBoostThreadDiscovery = true

            let diagnostic = "desktop pending threads discovered=\(debugThreadIDs(newlyDiscoveredThreadIDs)) "
                + "retrying=\(debugThreadIDs(unresolvedPendingThreadIDs)) "
                + "recent=\(trackedThreads.count) viewed=\(update.latestViewedAtByThreadID.count)"
            state.recordDiagnostic(diagnostic)
            effects.diagnostics.append(diagnostic)
        }

        return effects
    }

    private func prioritizedDesktopActivityCandidateRows(
        from trackedThreads: [AppStateStore.ThreadRow],
        observedAt: Date
    ) -> [AppStateStore.ThreadRow] {
        guard trackedThreads.count > DesktopActivityScanPolicy.candidateLimit else {
            return trackedThreads
        }

        let runtimeCutoff = observedAt.addingTimeInterval(-DesktopActivityScanPolicy.recentRuntimeLookback)
        let actionableRows = trackedThreads.filter { row in
            row.authoritativeListPresence == .pendingInclusion
                || row.listedStatus.isPending
                || row.presentationStatus == .running
                || row.presentationStatus == .failed
                || row.activeTurnID != nil
                || (row.lastRuntimeEventAt ?? .distantPast) >= runtimeCutoff
        }

        var candidateRows: [AppStateStore.ThreadRow] = []
        var seenThreadIDs: Set<String> = []

        func appendRows(_ rows: [AppStateStore.ThreadRow]) {
            for row in rows where candidateRows.count < DesktopActivityScanPolicy.candidateLimit {
                guard seenThreadIDs.insert(row.id).inserted else {
                    continue
                }
                candidateRows.append(row)
            }
        }

        appendRows(actionableRows)
        appendRows(trackedThreads)
        return candidateRows
    }

    func apply(notification: AppStateStore.NotificationEvent) {
        if let threadID = notification.unreadTrackingThreadID {
            armUnreadTracking(for: [threadID])
        }
        state.apply(notification: notification)

        if case let .threadStarted(notification) = notification {
            _ = pendingDiscoveredThreads.observe([notification.thread.id], now: now())
        }
    }

    func apply(serverRequest: AppStateStore.ServerRequestEvent) {
        state.apply(serverRequest: serverRequest)
    }

    @discardableResult
    func markWatched(thread: CodexThread) -> Bool {
        let previousRow = state.recentThreads.first(where: { $0.id == thread.id })
        state.markWatched(thread: thread)
        guard shouldMarkResumePayloadRead(previousRow: previousRow, threadID: thread.id),
              let updatedRow = state.recentThreads.first(where: { $0.id == thread.id }) else {
            return false
        }

        return threadReadMarkers.markRead(
            threadID: thread.id,
            lastTerminalActivityAt: updatedRow.lastTerminalActivityAt
        )
    }

    func markUnwatched(threadIDs: Set<String>) {
        state.markUnwatched(threadIDs: threadIDs)
    }

    func removeThreads(threadIDs: Set<String>) {
        state.removeThreads(threadIDs: threadIDs)
    }

    func clearLiveRuntimeState() {
        state.clearLiveRuntimeState()
    }

    func prepareSnapshot(
        additionalTrackedThreadIDs: Set<String> = [],
        projectLimit: Int? = nil,
        visibleThreadLimit: Int? = nil
    ) -> MenubarPreparedSnapshot {
        let effectiveProjectLimit = projectLimit ?? configuration.projectLimit
        let effectiveVisibleThreadLimit = visibleThreadLimit ?? configuration.visibleThreadLimit
        var snapshot = MenubarSnapshotSelector.makeSnapshot(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: threadReadMarkers,
            projectLimit: effectiveProjectLimit,
            visibleThreadLimit: effectiveVisibleThreadLimit,
            now: now()
        )
        let trackedSnapshotThreadIDs = trackedThreadIDs(in: snapshot)
        let didPruneReadMarkers = pruneThreadReadMarkersIfNeeded(
            now: now(),
            additionalTrackedThreadIDs: additionalTrackedThreadIDs.union(trackedSnapshotThreadIDs)
        )
        let didSeedReadMarkers = seedThreadReadMarkers(for: trackedSnapshotThreadIDs)
        let didChangeReadMarkers = didPruneReadMarkers || didSeedReadMarkers

        if didChangeReadMarkers {
            snapshot = MenubarSnapshotSelector.makeSnapshot(
                state: state,
                projectCatalog: projectCatalog,
                threadReadMarkers: threadReadMarkers,
                projectLimit: effectiveProjectLimit,
                visibleThreadLimit: effectiveVisibleThreadLimit,
                now: now()
            )
        }

        return MenubarPreparedSnapshot(
            snapshot: snapshot,
            didChangeReadMarkers: didChangeReadMarkers
        )
    }

    func visibleProjectSections() -> [AppStateStore.ProjectSection] {
        state.projectSections(
            using: projectCatalog,
            maxProjects: configuration.projectLimit,
            maxThreads: configuration.visibleThreadLimit
        )
    }

    func notificationBody(forThreadID threadID: String, fallback: String) -> String {
        state.notificationBody(forThreadID: threadID, fallback: fallback)
    }

    func markThreadRead(_ threadID: String) -> Bool {
        guard let thread = state.recentThreads.first(where: { $0.id == threadID }) else {
            return false
        }

        return threadReadMarkers.markRead(
            threadID: threadID,
            lastTerminalActivityAt: thread.lastTerminalActivityAt
        )
    }

    func seedThreadReadMarkers(for threadIDs: Set<String>) -> Bool {
        guard !threadIDs.isEmpty else {
            return false
        }

        var didChange = false
        let threadsByID = Dictionary(uniqueKeysWithValues: state.recentThreads.map { ($0.id, $0) })

        for threadID in threadIDs {
            guard let thread = threadsByID[threadID] else {
                continue
            }

            let seeded: Bool
            if thread.lastTerminalActivityAt != nil {
                seeded = threadReadMarkers.seedIfNeeded(
                    threadID: threadID,
                    lastTerminalActivityAt: thread.lastTerminalActivityAt
                )
            } else if thread.presentationStatus == .running || thread.presentationStatus == .waitingForUser {
                seeded = threadReadMarkers.armUnreadTrackingIfNeeded(threadID: threadID)
            } else {
                seeded = false
            }

            if seeded {
                didChange = true
            }
        }

        return didChange
    }

    private func armUnreadTracking(for threadIDs: Set<String>) {
        for threadID in threadIDs {
            _ = threadReadMarkers.armUnreadTrackingIfNeeded(threadID: threadID)
        }
    }

    private func shouldMarkResumePayloadRead(previousRow: AppStateStore.ThreadRow?, threadID: String) -> Bool {
        guard let previousRow,
              previousRow.lastTerminalActivityAt == nil,
              previousRow.presentationStatus != .running,
              previousRow.presentationStatus != .waitingForUser,
              let updatedRow = state.recentThreads.first(where: { $0.id == threadID }),
              updatedRow.lastTerminalActivityAt != nil,
              updatedRow.presentationStatus != .running,
              updatedRow.presentationStatus != .waitingForUser else {
            return false
        }

        return true
    }

    private func trackedThreadIDs(in snapshot: MenubarSnapshot) -> Set<String> {
        let projectSectionThreadIDs = snapshot.projectSections.flatMap { section in
            section.threads.map(\.id) + section.threadGroups.flatMap(\.childThreads).map(\.id)
        }
        let menuThreadIDs = snapshot.menuSections.flatMap { section in
            flattenedThreadIDs(from: section.threads)
        }

        return Set(projectSectionThreadIDs).union(menuThreadIDs)
    }

    private func flattenedThreadIDs(from threads: [ThreadMenuThread]) -> [String] {
        threads.flatMap { thread in
            [thread.thread.id] + flattenedThreadIDs(from: thread.children)
        }
    }

    private func recordDiscoveredThreadRefreshResult(threads: [CodexThread]) -> MenubarControllerEffects {
        guard pendingDiscoveredThreads.hasPendingThreads else {
            return MenubarControllerEffects()
        }

        let resolution = pendingDiscoveredThreads.resolve(with: Set(threads.map(\.id)), now: now())
        let diagnostic = "thread/list resolved=\(debugThreadIDs(resolution.resolvedThreadIDs)) "
            + "missing=\(debugThreadIDs(resolution.missingThreadIDs)) total=\(threads.count)"

        state.recordDiagnostic(diagnostic)
        return MenubarControllerEffects(
            diagnostics: [diagnostic],
            shouldBoostThreadDiscovery: !resolution.missingThreadIDs.isEmpty
        )
    }

    private func seedDiscoveredThreads(_ threadIDs: Set<String>) async -> MenubarControllerEffects {
        guard !threadIDs.isEmpty else {
            return MenubarControllerEffects()
        }

        do {
            let threads = try await loadThreadsByID(threadIDs)
            guard !threads.isEmpty else {
                let diagnostic = "state db had no discovered threads=\(debugThreadIDs(threadIDs))"
                state.recordDiagnostic(diagnostic)
                return MenubarControllerEffects(diagnostics: [diagnostic])
            }

            for thread in threads {
                state.mergeRecentThread(thread)
            }

            let diagnostic = "state db seeded threads=\(debugThreadIDs(threads.map(\.id)))"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(
                diagnostics: [diagnostic],
                shouldRequestThreadRefresh: false,
                shouldRequestDesktopActivityRefresh: true
            )
        } catch {
            let diagnostic = "failed to seed discovered threads: \(error.localizedDescription)"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        }
    }

    private func synchronizeThreadReadMarkers(from latestViewedAtByThreadID: [String: Date]) {
        guard !latestViewedAtByThreadID.isEmpty else { return }

        for thread in state.recentThreads {
            let viewedAt = latestViewedAtByThreadID[thread.id]
            _ = threadReadMarkers.markReadIfViewedAfterLastTerminalActivity(
                threadID: thread.id,
                lastTerminalActivityAt: thread.lastTerminalActivityAt,
                viewedAt: viewedAt
            )
        }
    }

    private func desktopArchiveHintThreadIDs(
        trackedThreads: [AppStateStore.ThreadRow],
        update: DesktopActivityUpdate
    ) -> Set<String> {
        Set(trackedThreads.compactMap { thread in
            guard let archivedAt = update.latestArchiveRequestedAtByThreadID[thread.id] else {
                return nil
            }

            let latestUnarchivedAt = update.latestUnarchiveRequestedAtByThreadID[thread.id] ?? .distantPast
            guard archivedAt > latestUnarchivedAt else {
                return nil
            }

            let freshnessFloor = max(thread.updatedAt, thread.lastRuntimeEventAt ?? .distantPast)
            guard archivedAt >= freshnessFloor else {
                return nil
            }

            return thread.id
        })
    }

    private func desktopUnarchiveHintThreadIDs(
        trackedThreads: [AppStateStore.ThreadRow],
        update: DesktopActivityUpdate
    ) -> Set<String> {
        let trackedThreadIDs = Set(trackedThreads.map(\.id))
        return Set(update.latestUnarchiveRequestedAtByThreadID.compactMap { threadID, unarchivedAt in
            guard trackedThreadIDs.contains(threadID) else {
                return nil
            }

            let archivedAt = update.latestArchiveRequestedAtByThreadID[threadID] ?? .distantPast
            guard unarchivedAt > archivedAt else {
                return nil
            }

            return threadID
        })
    }

    private func synchronizePendingAuthoritativeThreads() {
        state.prunePendingAuthoritativeThreads(
            keeping: pendingDiscoveredThreads.pendingThreadIDs
        )
    }

    private func pruneThreadReadMarkersIfNeeded(
        now: Date,
        additionalTrackedThreadIDs: Set<String>
    ) -> Bool {
        let trackedThreadIDs = Set(state.recentThreads.map(\.id)).union(additionalTrackedThreadIDs)
        let minimumTimestamp = now.addingTimeInterval(-configuration.threadReadMarkerRetentionSeconds).timeIntervalSince1970
        return threadReadMarkers.prune(keeping: trackedThreadIDs, minimumTimestamp: minimumTimestamp)
    }

    private func hydratedRecentThreads(limit: Int) async throws -> [CodexThread] {
        let threads = try await loadRecentThreads(limit)
        return try await hydrateThreads(threads)
    }

    private func hydrateThreads(_ threads: [CodexThread]) async throws -> [CodexThread] {
        guard !threads.isEmpty else {
            return []
        }

        let threadIDsNeedingMetadata = Set(
            threads.compactMap { thread in
                requiresMetadataHydration(for: thread) ? thread.id : nil
            }
        )
        guard !threadIDsNeedingMetadata.isEmpty else {
            return threads
        }

        let metadataByID = Dictionary(
            uniqueKeysWithValues: (try? await loadThreadsByID(threadIDsNeedingMetadata))?.map { ($0.id, $0) } ?? []
        )

        return threads.map { thread in
            guard let metadata = metadataByID[thread.id] else {
                return thread
            }

            return thread.mergingMetadata(from: metadata)
        }
    }

    private func requiresMetadataHydration(for thread: CodexThread) -> Bool {
        thread.path == nil
            || thread.source == nil
            || thread.agentRole == nil
            || thread.agentNickname == nil
    }

    private func bootstrapRecentThreads(
        projectLimit: Int,
        visibleThreadLimit: Int
    ) async throws -> [CodexThread] {
        let initialLimit = min(
            configuration.maxTrackedThreads,
            max(configuration.initialFetchLimit, projectLimit * visibleThreadLimit)
        )
        var limit = max(1, initialLimit)
        var threads = try await loadRecentThreads(limit)

        while shouldExpandBootstrapThreads(
            threads,
            desiredProjectCount: projectLimit,
            loadedLimit: limit
        ) {
            let nextLimit = min(configuration.maxTrackedThreads, max(limit + 1, limit * 2))
            guard nextLimit > limit else {
                break
            }

            limit = nextLimit
            threads = try await loadRecentThreads(limit)
        }

        return try await hydrateThreads(threads)
    }

    private func shouldExpandBootstrapThreads(
        _ threads: [CodexThread],
        desiredProjectCount: Int,
        loadedLimit: Int
    ) -> Bool {
        guard loadedLimit < configuration.maxTrackedThreads else {
            return false
        }

        guard threads.count >= loadedLimit else {
            return false
        }

        return bootstrapProjectCount(in: threads) < desiredProjectCount
    }

    private func bootstrapProjectCount(in threads: [CodexThread]) -> Int {
        Set(threads.map { projectCatalog.project(forThreadID: $0.id, cwd: $0.cwd).id }).count
    }

    private func debugThreadIDs<S: Sequence>(_ threadIDs: S) -> String where S.Element == String {
        let sortedThreadIDs = threadIDs.sorted()
        guard !sortedThreadIDs.isEmpty else {
            return "[]"
        }

        let sample = sortedThreadIDs.prefix(3).map { String($0.prefix(8)) }
        let suffix = sortedThreadIDs.count > sample.count ? ",+\(sortedThreadIDs.count - sample.count)" : ""
        return "[" + sample.joined(separator: ",") + suffix + "]"
    }

}
