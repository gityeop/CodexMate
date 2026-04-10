import Foundation

protocol DesktopActivityLoading: Sendable {
    func load(candidateSessionPaths: [String: String?], now: Date) async -> DesktopActivityUpdate
}

protocol RecentThreadListing: Sendable {
    func recentThreads(limit: Int) async throws -> [CodexThread]
}

protocol ThreadMetadataReading: Sendable {
    func threads(threadIDs: Set<String>) async throws -> [CodexThread]
}

protocol ProjectCatalogLoading: Sendable {
    func loadProjectCatalog() async throws -> CodexDesktopProjectCatalog
}

extension DesktopActivityService: DesktopActivityLoading {}

actor DesktopStateRecentThreadListing: RecentThreadListing {
    private let reader: CodexDesktopStateReader

    init(codexDirectoryURLProvider: @escaping @Sendable () -> URL) {
        reader = CodexDesktopStateReader(codexDirectoryURLProvider: codexDirectoryURLProvider)
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        try reader.recentThreads(limit: limit)
    }
}

actor DesktopStateThreadMetadataReader: ThreadMetadataReading {
    private let reader: CodexDesktopStateReader

    init(codexDirectoryURLProvider: @escaping @Sendable () -> URL) {
        reader = CodexDesktopStateReader(codexDirectoryURLProvider: codexDirectoryURLProvider)
    }

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        try reader.threads(threadIDs: threadIDs)
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

@MainActor
final class FallbackRecentThreadListing: RecentThreadListing, @unchecked Sendable {
    private let primary: any RecentThreadListing
    private let fallback: any RecentThreadListing

    init(primary: any RecentThreadListing, fallback: any RecentThreadListing) {
        self.primary = primary
        self.fallback = fallback
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        async let primaryOutcome = fetchRecentThreadsResult(using: primary, limit: limit)
        async let fallbackOutcome = fetchRecentThreadsResult(using: fallback, limit: limit)

        switch await primaryOutcome {
        case let .success(primaryThreads):
            switch await fallbackOutcome {
            case let .success(fallbackThreads):
                return mergedThreads(
                    primaryThreads: primaryThreads,
                    fallbackThreads: fallbackThreads,
                    limit: limit
                )
            case .failure:
                return Array(primaryThreads.prefix(limit))
            }
        case let .failure(primaryError):
            switch await fallbackOutcome {
            case let .success(fallbackThreads):
                return Array(fallbackThreads.prefix(limit))
            case .failure:
                throw primaryError
            }
        }
    }

    private func mergedThreads(
        primaryThreads: [CodexThread],
        fallbackThreads: [CodexThread],
        limit: Int
    ) -> [CodexThread] {
        guard !primaryThreads.isEmpty else {
            return Array(fallbackThreads.prefix(limit))
        }

        let fallbackThreadsByID = Dictionary(uniqueKeysWithValues: fallbackThreads.map { ($0.id, $0) })
        var mergedThreadsByID: [String: CodexThread] = [:]

        for thread in primaryThreads {
            guard mergedThreadsByID[thread.id] == nil else {
                continue
            }

            if let fallbackThread = fallbackThreadsByID[thread.id] {
                mergedThreadsByID[thread.id] = thread.mergingMetadata(from: fallbackThread)
            } else {
                mergedThreadsByID[thread.id] = thread
            }
        }

        for thread in fallbackThreads {
            guard mergedThreadsByID[thread.id] == nil else {
                continue
            }

            mergedThreadsByID[thread.id] = thread
        }

        return mergedThreadsByID.values
            .sorted(by: Self.isHigherPriorityRecentThread)
            .prefix(max(0, limit))
            .map { $0 }
    }

    private static func isHigherPriorityRecentThread(_ lhs: CodexThread, _ rhs: CodexThread) -> Bool {
        if lhs.updatedAt == rhs.updatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.updatedAt > rhs.updatedAt
    }

    private func fetchRecentThreadsResult(
        using listing: any RecentThreadListing,
        limit: Int
    ) async -> Result<[CodexThread], Error> {
        do {
            return .success(try await listing.recentThreads(limit: limit))
        } catch {
            return .failure(error)
        }
    }
}

struct MenubarControllerConfiguration {
    let initialFetchLimit: Int
    let maxTrackedThreads: Int
    let projectLimit: Int
    let visibleThreadLimit: Int
    let maxPendingDiscoveredThreads: Int
    let pendingDiscoveredThreadTTL: TimeInterval
    let threadReadMarkerRetentionSeconds: TimeInterval
}

struct MenubarControllerEffects: Equatable {
    var diagnostics: [String] = []
    var shouldRequestThreadRefresh = false
    var shouldRequestDesktopActivityRefresh = false
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

@MainActor
final class MenubarController {
    private let loadDesktopActivity: @Sendable ([String: String?], Date) async -> DesktopActivityUpdate
    private let loadRecentThreads: @Sendable (Int) async throws -> [CodexThread]
    private let loadThreadsByID: (Set<String>) async throws -> [CodexThread]
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
        self.loadDesktopActivity = { candidateSessionPaths, now in
            await desktopActivityLoader.load(candidateSessionPaths: candidateSessionPaths, now: now)
        }
        self.loadRecentThreads = { limit in
            try await recentThreadListing.recentThreads(limit: limit)
        }
        self.loadThreadsByID = { threadIDs in
            try await threadMetadataReader.threads(threadIDs: threadIDs)
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
        let authoritativeThreadIDs = Set(threads.map(\.id))
        let omittedListedThreadIDs = listedThreadIDsMissingFromAuthoritativeList(keeping: authoritativeThreadIDs)
        var effects = recordDiscoveredThreadRefreshResult(threads: threads)
        projectCatalog = (try? await loadProjectCatalog()) ?? .empty
        state.replaceRecentThreads(with: threads)
        let omissionEffects = await pruneAuthoritativeListOmissions(omittedListedThreadIDs)
        effects.diagnostics.append(contentsOf: omissionEffects.diagnostics)
        effects.shouldRequestThreadRefresh = effects.shouldRequestThreadRefresh
            || omissionEffects.shouldRequestThreadRefresh
        effects.shouldRequestDesktopActivityRefresh = effects.shouldRequestDesktopActivityRefresh
            || omissionEffects.shouldRequestDesktopActivityRefresh
        effects.shouldBoostThreadDiscovery = effects.shouldBoostThreadDiscovery
            || omissionEffects.shouldBoostThreadDiscovery
        synchronizePendingAuthoritativeThreads()
        return effects
    }

    func pruneThreadsMissingFromDesktopState() async -> MenubarControllerEffects {
        let pruneGraceCutoff = now().addingTimeInterval(-configuration.pendingDiscoveredThreadTTL)
        let candidateThreadIDs: Set<String> = Set(
            state.recentThreads
                .filter { $0.updatedAt <= pruneGraceCutoff }
                .map(\.id)
        )

        guard !candidateThreadIDs.isEmpty else {
            return MenubarControllerEffects()
        }

        do {
            let presentThreadIDs = Set(try await loadThreadsByID(candidateThreadIDs).map(\.id))
            let missingThreadIDs = candidateThreadIDs.subtracting(presentThreadIDs)

            guard !missingThreadIDs.isEmpty else {
                return MenubarControllerEffects()
            }

            state.removeThreads(threadIDs: missingThreadIDs)
            let diagnostic = "desktop pruned missing threads=\(debugThreadIDs(missingThreadIDs))"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        } catch {
            let diagnostic = "desktop prune skipped: \(error.localizedDescription)"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        }
    }

    func refreshDesktopActivity() async -> MenubarControllerEffects {
        pendingDiscoveredThreads.prune(now: now())
        synchronizePendingAuthoritativeThreads()

        let trackedThreads = state.recentThreads
        let candidateSessionPaths = Dictionary(
            uniqueKeysWithValues: trackedThreads.map { ($0.id, $0.sessionPath) }
        )
        let activityObservedAt = now()
        let update = await loadDesktopActivity(candidateSessionPaths, activityObservedAt)
        let isConnected = state.connection.isConnected
        let recentThreadIDs = Set(trackedThreads.map(\.id))
        let attentionThreadIDs = Set(update.runtimeSnapshot?.waitingForInputThreadIDs ?? [])
            .union(update.runtimeSnapshot?.approvalThreadIDs ?? [])
            .union(Set(update.runtimeSnapshot?.failedThreads.keys.map { $0 } ?? []))
        let discoveredThreadIDs = ThreadActivityRefreshPlanner.discoveredThreadIDsNeedingRefresh(
            recentThreadIDs: recentThreadIDs,
            latestViewedAtByThreadID: update.latestViewedAtByThreadID,
            recentActivityThreadIDs: update.runtimeSnapshot?.recentActivityThreadIDs ?? [],
            attentionThreadIDs: attentionThreadIDs,
            now: activityObservedAt
        )
        let newlyDiscoveredThreadIDs = pendingDiscoveredThreads.observe(discoveredThreadIDs, now: activityObservedAt)
        let unresolvedPendingThreadIDs = pendingDiscoveredThreads.pendingThreadIDs.subtracting(recentThreadIDs)
        let threadIDsToSeed = newlyDiscoveredThreadIDs.union(unresolvedPendingThreadIDs)

        var effects = MenubarControllerEffects()

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
        state.apply(desktopCompletionHints: update.latestTurnCompletedAtByThreadID)

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

    func apply(notification: AppStateStore.NotificationEvent) {
        state.apply(notification: notification)

        if case let .threadStarted(notification) = notification {
            _ = pendingDiscoveredThreads.observe([notification.thread.id], now: now())
        }
    }

    func apply(serverRequest: AppStateStore.ServerRequestEvent) {
        state.apply(serverRequest: serverRequest)
    }

    func markWatched(thread: CodexThread) {
        state.markWatched(thread: thread)
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
            visibleThreadLimit: effectiveVisibleThreadLimit
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
                visibleThreadLimit: effectiveVisibleThreadLimit
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

        for threadID in threadIDs {
            if threadReadMarkers.seedIfNeeded(threadID: threadID) {
                didChange = true
            }
        }

        return didChange
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

    private func listedThreadIDsMissingFromAuthoritativeList(keeping threadIDs: Set<String>) -> Set<String> {
        Set(
            state.recentThreads.compactMap { thread in
                guard thread.authoritativeListPresence == .listed,
                      thread.parentThreadID == nil,
                      !threadIDs.contains(thread.id) else {
                    return nil
                }

                return thread.id
            }
        )
    }

    private func pruneAuthoritativeListOmissions(_ threadIDs: Set<String>) async -> MenubarControllerEffects {
        guard !threadIDs.isEmpty else {
            return MenubarControllerEffects()
        }

        do {
            let presentThreadIDs = Set(try await loadThreadsByID(threadIDs).map(\.id))
            let missingThreadIDs = threadIDs.subtracting(presentThreadIDs)

            guard !missingThreadIDs.isEmpty else {
                return MenubarControllerEffects()
            }

            state.archiveThreads(threadIDs: missingThreadIDs)
            let diagnostic = "thread/list pruned missing listed threads=\(debugThreadIDs(missingThreadIDs))"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        } catch {
            let diagnostic = "thread/list omission prune skipped: \(error.localizedDescription)"
            state.recordDiagnostic(diagnostic)
            return MenubarControllerEffects(diagnostics: [diagnostic])
        }
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
        Set(threads.map { projectCatalog.project(for: $0.cwd).id }).count
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
