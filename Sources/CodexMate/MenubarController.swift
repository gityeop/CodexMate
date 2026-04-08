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
        async let primaryResult = fetchRecentThreadsResult(using: primary, limit: limit)
        async let fallbackResult = fetchRecentThreadsResult(using: fallback, limit: limit)

        let primaryOutcome = await primaryResult
        let fallbackOutcome = await fallbackResult

        switch (primaryOutcome, fallbackOutcome) {
        case let (.success(primaryThreads), .success(fallbackThreads)):
            return mergeRecentThreads(primary: primaryThreads, fallback: fallbackThreads, limit: limit)
        case let (.success(primaryThreads), .failure):
            return Array(primaryThreads.prefix(limit))
        case let (.failure, .success(fallbackThreads)):
            return Array(fallbackThreads.prefix(limit))
        case let (.failure(primaryError), .failure):
            throw primaryError
        }
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

    private func mergeRecentThreads(primary: [CodexThread], fallback: [CodexThread], limit: Int) -> [CodexThread] {
        guard !primary.isEmpty else {
            return Array(fallback.prefix(limit))
        }

        guard !fallback.isEmpty else {
            return Array(primary.prefix(limit))
        }

        var mergedByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        for thread in primary {
            mergedByID[thread.id] = thread
        }

        return mergedByID.values
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
                }

                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
            .map { $0 }
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

    var id: String {
        section.id
    }
}

struct MenubarSnapshot: Equatable {
    let overallStatus: AppStateStore.OverallStatus
    let hasUnreadThreads: Bool
    let projectSections: [MenubarProjectSectionSnapshot]
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
    }

    func refreshThreads() async throws -> MenubarControllerEffects {
        let threads = try await hydratedRecentThreads(limit: configuration.maxTrackedThreads)
        let effects = recordDiscoveredThreadRefreshResult(threads: threads)
        projectCatalog = (try? await loadProjectCatalog()) ?? .empty
        state.replaceRecentThreads(with: threads)
        return effects
    }

    func refreshDesktopActivity() async -> MenubarControllerEffects {
        pendingDiscoveredThreads.prune(now: now())

        let trackedThreads = state.recentThreads
        let candidateSessionPaths = Dictionary(
            uniqueKeysWithValues: trackedThreads.map { ($0.id, $0.sessionPath) }
        )
        let activityObservedAt = now()
        let update = await loadDesktopActivity(candidateSessionPaths, activityObservedAt)
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

        var effects = MenubarControllerEffects()

        if let runtimeSnapshot = update.runtimeSnapshot {
            state.apply(desktopSnapshot: runtimeSnapshot, observedAt: activityObservedAt)

            if runtimeSnapshot.activeTurnCount > 0,
               !state.recentThreads.contains(where: { $0.presentationStatus == .running }) {
                effects.shouldRequestThreadRefresh = true

                let diagnostic = "desktop observed active turn without tracked running thread "
                    + "activeTurns=\(runtimeSnapshot.activeTurnCount) recent=\(trackedThreads.count)"
                state.recordDiagnostic(diagnostic)
                effects.diagnostics.append(diagnostic)
            }
        } else if let runtimeErrorMessage = update.runtimeErrorMessage {
            let diagnostic = "Desktop activity unavailable: \(runtimeErrorMessage)"
            state.recordDiagnostic(diagnostic)
            effects.diagnostics.append(diagnostic)
        }

        state.apply(desktopCompletionHints: update.latestTurnCompletedAtByThreadID)
        synchronizeThreadReadMarkers(from: update.latestViewedAtByThreadID)

        if !newlyDiscoveredThreadIDs.isEmpty {
            let seedEffects = await seedDiscoveredThreads(newlyDiscoveredThreadIDs)
            effects.diagnostics.append(contentsOf: seedEffects.diagnostics)
            effects.shouldRequestDesktopActivityRefresh = seedEffects.shouldRequestDesktopActivityRefresh
            effects.shouldRequestThreadRefresh = true

            let diagnostic = "desktop discovered new threads=\(debugThreadIDs(newlyDiscoveredThreadIDs)) "
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
        let snapshotSections = projectSectionsWithSubagentThreads(
            projectLimit: effectiveProjectLimit,
            visibleThreadLimit: effectiveVisibleThreadLimit
        )
        let displayedThreads = snapshotSections.flatMap { section in
            section.threads + section.threadGroups.flatMap(\.childThreads)
        }
        let displayedThreadIDs = Set(displayedThreads.map(\.id))
        let didChangeReadMarkers = pruneThreadReadMarkersIfNeeded(
            now: now(),
            additionalTrackedThreadIDs: additionalTrackedThreadIDs.union(displayedThreadIDs)
        ) || synchronizeThreadReadMarkers(with: displayedThreads)
        let hasUnreadThreads = snapshotSections.flatMap { section in
            section.threads + section.threadGroups.flatMap(\.childThreads)
        }
        .contains(where: \.hasUnreadContent)
        let displayOverallStatus = displayedOverallStatus(snapshotSections: snapshotSections)

        return MenubarPreparedSnapshot(
            snapshot: MenubarSnapshot(
                overallStatus: displayOverallStatus,
                hasUnreadThreads: hasUnreadThreads,
                projectSections: snapshotSections,
                isWatchLatestThreadEnabled: !state.visibleRecentThreads.isEmpty
            ),
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

    private func recordDiscoveredThreadRefreshResult(threads: [CodexThread]) -> MenubarControllerEffects {
        guard pendingDiscoveredThreads.hasPendingThreads else {
            return MenubarControllerEffects()
        }

        let resolution = pendingDiscoveredThreads.resolve(with: Set(threads.map(\.id)), now: now())
        let diagnostic = "thread/list resolved=\(debugThreadIDs(resolution.resolvedThreadIDs)) "
            + "missing=\(debugThreadIDs(resolution.missingThreadIDs)) total=\(threads.count)"

        state.recordDiagnostic(diagnostic)
        return MenubarControllerEffects(diagnostics: [diagnostic])
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

    private func synchronizeThreadReadMarkers(with threads: [MenubarThreadSnapshot]) -> Bool {
        var didChange = false

        for thread in threads {
            if threadReadMarkers.seedIfNeeded(threadID: thread.id) {
                didChange = true
            }
        }

        return didChange
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

    private func projectSectionsWithSubagentThreads(
        projectLimit: Int,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let allThreads = state.recentThreads
        guard !allThreads.isEmpty else { return [] }

        struct Bucket {
            let id: String
            let displayName: String
            var latestUpdatedAt: Date
            var threadRowsByID: [String: AppStateStore.ThreadRow]
            var orderedThreads: [AppStateStore.ThreadRow]
        }

        var bucketsByProjectID: [String: Bucket] = [:]

        for thread in allThreads {
            let project = projectCatalog.project(for: thread.cwd)
            if var bucket = bucketsByProjectID[project.id] {
                bucket.latestUpdatedAt = max(bucket.latestUpdatedAt, thread.activityUpdatedAt)
                bucket.threadRowsByID[thread.id] = thread
                bucket.orderedThreads.append(thread)
                bucketsByProjectID[project.id] = bucket
            } else {
                bucketsByProjectID[project.id] = Bucket(
                    id: project.id,
                    displayName: project.displayName,
                    latestUpdatedAt: thread.activityUpdatedAt,
                    threadRowsByID: [thread.id: thread],
                    orderedThreads: [thread]
                )
            }
        }

        let buckets = bucketsByProjectID.values.sorted { lhs, rhs in
            if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

            return lhs.latestUpdatedAt > rhs.latestUpdatedAt
        }

        let sections = buckets.map { bucket in
            let orderedThreads = bucket.orderedThreads.sorted(by: Self.isNewerThread)
            let childThreadIDs: Set<String> = Set(
                orderedThreads.compactMap { thread in
                    guard let parentThreadID = thread.parentThreadID,
                          bucket.threadRowsByID[parentThreadID] != nil else {
                        return nil
                    }

                    return thread.id
                }
            )

            let topLevelThreads = orderedThreads.filter { !childThreadIDs.contains($0.id) }
            let threadSnapshotsByID = Dictionary(
                uniqueKeysWithValues: orderedThreads.map { thread in
                    (thread.id, makeThreadSnapshot(thread))
                }
            )

            let threadGroups = topLevelThreads.compactMap { thread -> MenubarThreadGroupSnapshot? in
                let childThreads = orderedThreads.compactMap { candidate -> MenubarThreadSnapshot? in
                    guard candidate.parentThreadID == thread.id else { return nil }
                    return threadSnapshotsByID[candidate.id]
                }

                guard !childThreads.isEmpty else { return nil }
                guard let parentSnapshot = threadSnapshotsByID[thread.id] else { return nil }

                return MenubarThreadGroupSnapshot(thread: parentSnapshot, childThreads: childThreads)
            }

            return MenubarProjectSectionSnapshot(
                section: AppStateStore.ProjectSection(
                    id: bucket.id,
                    displayName: bucket.displayName,
                    latestUpdatedAt: bucket.latestUpdatedAt,
                    threads: topLevelThreads
                ),
                threads: topLevelThreads.map(makeThreadSnapshot),
                threadGroups: threadGroups
            )
        }

        guard projectLimit != .max || visibleThreadLimit != .max else {
            return sections
        }

        return limitProjectSections(
            sections,
            projectLimit: projectLimit,
            visibleThreadLimit: visibleThreadLimit
        )
    }

    private static func isNewerThread(_ lhs: AppStateStore.ThreadRow, _ rhs: AppStateStore.ThreadRow) -> Bool {
        if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.activityUpdatedAt > rhs.activityUpdatedAt
    }

    private func limitProjectSections(
        _ sections: [MenubarProjectSectionSnapshot],
        projectLimit: Int,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let visibleProjectLimit = max(0, projectLimit)
        let visibleThreadLimit = max(0, visibleThreadLimit)
        let orderedSections: [MenubarProjectSectionSnapshot]

        if sections.count > visibleProjectLimit {
            orderedSections = sections.sorted(by: Self.isHigherPriorityProjectSection)
        } else {
            orderedSections = sections
        }

        let limitedSections = Array(orderedSections.prefix(visibleProjectLimit))

        return limitedSections.map { section in
            let orderedThreads: [MenubarThreadSnapshot]
            if section.threads.count > visibleThreadLimit {
                orderedThreads = Self.prioritizedThreads(in: section)
            } else {
                orderedThreads = section.threads
            }

            let limitedThreads = Array(orderedThreads.prefix(visibleThreadLimit))
            let threadGroupsByID = Dictionary(uniqueKeysWithValues: section.threadGroups.map { ($0.id, $0) })
            let limitedThreadGroups = limitedThreads.compactMap { threadGroupsByID[$0.id] }

            return MenubarProjectSectionSnapshot(
                section: AppStateStore.ProjectSection(
                    id: section.section.id,
                    displayName: section.section.displayName,
                    latestUpdatedAt: section.section.latestUpdatedAt,
                    threads: limitedThreads.map(\.thread)
                ),
                threads: limitedThreads,
                threadGroups: limitedThreadGroups
            )
        }
    }

    private static func isHigherPriorityProjectSection(
        _ lhs: MenubarProjectSectionSnapshot,
        _ rhs: MenubarProjectSectionSnapshot
    ) -> Bool {
        let lhsRank = visibilityPriority(for: lhs)
        let rhsRank = visibilityPriority(for: rhs)

        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        if lhs.section.latestUpdatedAt == rhs.section.latestUpdatedAt {
            return lhs.section.displayName.localizedCaseInsensitiveCompare(rhs.section.displayName) == .orderedAscending
        }

        return lhs.section.latestUpdatedAt > rhs.section.latestUpdatedAt
    }

    private static func prioritizedThreads(in section: MenubarProjectSectionSnapshot) -> [MenubarThreadSnapshot] {
        let threadGroupsByID = Dictionary(uniqueKeysWithValues: section.threadGroups.map { ($0.id, $0) })

        return section.threads.sorted { lhs, rhs in
            let lhsRank = visibilityPriority(
                for: lhs,
                childThreads: threadGroupsByID[lhs.id]?.childThreads ?? []
            )
            let rhsRank = visibilityPriority(
                for: rhs,
                childThreads: threadGroupsByID[rhs.id]?.childThreads ?? []
            )

            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }

            return isNewerThread(lhs.thread, rhs.thread)
        }
    }

    private static func visibilityPriority(for section: MenubarProjectSectionSnapshot) -> Int {
        let threadGroupsByID = Dictionary(uniqueKeysWithValues: section.threadGroups.map { ($0.id, $0) })

        return section.threads.map { thread in
            visibilityPriority(
                for: thread,
                childThreads: threadGroupsByID[thread.id]?.childThreads ?? []
            )
        }.max() ?? 0
    }

    private static func visibilityPriority(
        for threadSnapshot: MenubarThreadSnapshot,
        childThreads: [MenubarThreadSnapshot] = []
    ) -> Int {
        max(
            visibilityPriority(for: threadSnapshot.thread),
            childThreads.map { visibilityPriority(for: $0.thread) }.max() ?? 0
        )
    }

    private static func visibilityPriority(for thread: AppStateStore.ThreadRow) -> Int {
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

    private func makeThreadSnapshot(_ thread: AppStateStore.ThreadRow) -> MenubarThreadSnapshot {
        MenubarThreadSnapshot(
            thread: thread,
            hasUnreadContent: threadReadMarkers.hasUnreadContent(
                threadID: thread.id,
                lastTerminalActivityAt: thread.lastTerminalActivityAt
            )
        )
    }

    private func displayedOverallStatus(
        snapshotSections: [MenubarProjectSectionSnapshot]
    ) -> AppStateStore.OverallStatus {
        if state.connection == .connecting {
            return .connecting
        }

        let displayedMainThreads = snapshotSections
            .flatMap(\.threads)
            .map(\.thread)
            .filter { !$0.isSubagent }

        if displayedMainThreads.contains(where: { $0.presentationStatus == .waitingForUser }) {
            return .waitingForUser
        }

        if displayedMainThreads.contains(where: { $0.presentationStatus == .running }) {
            return .running
        }

        if state.overallStatus == .running {
            return .running
        }

        if state.connection.isFailed {
            return .failed
        }

        if displayedMainThreads.contains(where: { $0.presentationStatus == .failed }) {
            return .failed
        }

        return .idle
    }
}
