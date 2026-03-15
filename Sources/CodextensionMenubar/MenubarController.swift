import Foundation

protocol DesktopActivityLoading: Sendable {
    func load(candidateSessionPaths: [String: String?], now: Date) async -> DesktopActivityUpdate
}

protocol RecentThreadListing: Sendable {
    func recentThreads(limit: Int) async throws -> [CodexThread]
}

protocol ThreadMetadataReading {
    func threads(threadIDs: Set<String>) throws -> [CodexThread]
}

protocol ProjectCatalogLoading {
    func loadProjectCatalog() throws -> CodexDesktopProjectCatalog
}

extension DesktopActivityService: DesktopActivityLoading {}
extension CodexDesktopStateReader: ThreadMetadataReading {}

extension CodexDesktopProjectCatalogReader: ProjectCatalogLoading {
    func loadProjectCatalog() throws -> CodexDesktopProjectCatalog {
        try load()
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
            let response: ThreadListResponse = try await client.call(
                method: "thread/list",
                params: ThreadListParams(
                    cursor: cursor,
                    limit: fetchPageLimit,
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

struct MenubarProjectSectionSnapshot: Equatable, Identifiable {
    let section: AppStateStore.ProjectSection
    let threads: [MenubarThreadSnapshot]

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
    private let loadThreadsByID: (Set<String>) throws -> [CodexThread]
    private let loadProjectCatalog: () throws -> CodexDesktopProjectCatalog
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
            try threadMetadataReader.threads(threadIDs: threadIDs)
        }
        self.loadProjectCatalog = {
            try projectCatalogLoader.loadProjectCatalog()
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

    var persistedThreadReadMarkers: [String: TimeInterval] {
        threadReadMarkers.lastReadTerminalAtByThreadID
    }

    func setConnection(_ connection: AppStateStore.ConnectionState) {
        state.setConnection(connection)
    }

    func recordDiagnostic(_ diagnostic: String) {
        state.recordDiagnostic(diagnostic)
    }

    func loadInitialThreads() async throws {
        let threads = try await loadRecentThreads(configuration.initialFetchLimit)
        projectCatalog = (try? loadProjectCatalog()) ?? .empty
        state.replaceRecentThreads(with: threads)
    }

    func refreshThreads() async throws -> MenubarControllerEffects {
        let threads = try await loadRecentThreads(configuration.maxTrackedThreads)
        let effects = recordDiscoveredThreadRefreshResult(threads: threads)
        projectCatalog = (try? loadProjectCatalog()) ?? .empty
        state.replaceRecentThreads(with: threads)
        return effects
    }

    func refreshDesktopActivity() async -> MenubarControllerEffects {
        pendingDiscoveredThreads.prune(now: now())

        let candidateSessionPaths = Dictionary(
            uniqueKeysWithValues: state.recentThreads.map { ($0.id, $0.sessionPath) }
        )
        let activityObservedAt = now()
        let update = await loadDesktopActivity(candidateSessionPaths, activityObservedAt)
        let recentThreadIDs = Set(state.recentThreads.map(\.id))
        let discoveredThreadIDs = ThreadActivityRefreshPlanner.discoveredThreadIDsNeedingRefresh(
            recentThreadIDs: recentThreadIDs,
            latestViewedAtByThreadID: update.latestViewedAtByThreadID,
            recentActivityThreadIDs: update.runtimeSnapshot?.recentActivityThreadIDs ?? [],
            now: activityObservedAt
        )
        let newlyDiscoveredThreadIDs = pendingDiscoveredThreads.observe(discoveredThreadIDs, now: activityObservedAt)

        var effects = MenubarControllerEffects()

        if let runtimeSnapshot = update.runtimeSnapshot {
            state.apply(desktopSnapshot: runtimeSnapshot, observedAt: activityObservedAt)
        } else if let runtimeErrorMessage = update.runtimeErrorMessage {
            let diagnostic = "Desktop activity unavailable: \(runtimeErrorMessage)"
            state.recordDiagnostic(diagnostic)
            effects.diagnostics.append(diagnostic)
        }

        state.apply(desktopCompletionHints: update.latestTurnCompletedAtByThreadID)
        synchronizeThreadReadMarkers(from: update.latestViewedAtByThreadID)

        if !newlyDiscoveredThreadIDs.isEmpty {
            let seedEffects = seedDiscoveredThreads(newlyDiscoveredThreadIDs)
            effects.diagnostics.append(contentsOf: seedEffects.diagnostics)
            effects.shouldRequestDesktopActivityRefresh = seedEffects.shouldRequestDesktopActivityRefresh
            effects.shouldRequestThreadRefresh = true

            let diagnostic = "desktop discovered new threads=\(debugThreadIDs(newlyDiscoveredThreadIDs)) "
                + "recent=\(state.recentThreads.count) viewed=\(update.latestViewedAtByThreadID.count)"
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

    func prepareSnapshot(additionalTrackedThreadIDs: Set<String> = []) -> MenubarPreparedSnapshot {
        let didChangeReadMarkers = pruneThreadReadMarkersIfNeeded(
            now: now(),
            additionalTrackedThreadIDs: additionalTrackedThreadIDs
        ) || synchronizeThreadReadMarkers()
        let sections = visibleProjectSections()
        let snapshotSections = sections.map { section in
            MenubarProjectSectionSnapshot(
                section: section,
                threads: section.threads.map { thread in
                    MenubarThreadSnapshot(
                        thread: thread,
                        hasUnreadContent: threadReadMarkers.hasUnreadContent(
                            threadID: thread.id,
                            lastTerminalActivityAt: thread.lastTerminalActivityAt
                        )
                    )
                }
            )
        }
        let hasUnreadThreads = snapshotSections.flatMap(\.threads).contains(where: \.hasUnreadContent)

        return MenubarPreparedSnapshot(
            snapshot: MenubarSnapshot(
                overallStatus: state.overallStatus,
                hasUnreadThreads: hasUnreadThreads,
                projectSections: snapshotSections,
                isWatchLatestThreadEnabled: !state.recentThreads.isEmpty
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

    private func seedDiscoveredThreads(_ threadIDs: Set<String>) -> MenubarControllerEffects {
        guard !threadIDs.isEmpty else {
            return MenubarControllerEffects()
        }

        do {
            let threads = try loadThreadsByID(threadIDs)
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

    private func synchronizeThreadReadMarkers() -> Bool {
        var didChange = false

        for thread in state.recentThreads {
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
