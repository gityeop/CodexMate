import Foundation

enum MenubarSnapshotSelector {
    private static let unmatchedProjectGraceInterval: TimeInterval = 2 * 60

    static func makeSnapshot(
        state: AppStateStore,
        projectCatalog: CodexDesktopProjectCatalog,
        threadReadMarkers: ThreadReadMarkerStore,
        projectLimit: Int,
        visibleThreadLimit: Int,
        now: Date = Date()
    ) -> MenubarSnapshot {
        let projectSections = projectSectionsWithSubagentThreads(
            state: state,
            projectCatalog: projectCatalog,
            threadReadMarkers: threadReadMarkers,
            projectLimit: projectLimit,
            visibleThreadLimit: visibleThreadLimit,
            now: now
        )
        let menuSections = ThreadMenuBuilder.build(snapshotSections: projectSections)
        let hasVisibleSnapshotThreads = projectSections.contains { !$0.allThreads.isEmpty }

        return MenubarSnapshot(
            overallStatus: displayedOverallStatus(
                state: state,
                snapshotSections: projectSections
            ),
            hasUnreadThreads: menuSections
                .flatMap(\.threads)
                .contains(where: hasUnreadContent),
            projectSections: projectSections,
            menuSections: menuSections,
            hasRecentThreads: hasVisibleSnapshotThreads,
            isWatchLatestThreadEnabled: hasVisibleSnapshotThreads
        )
    }

    private static func projectSectionsWithSubagentThreads(
        state: AppStateStore,
        projectCatalog: CodexDesktopProjectCatalog,
        threadReadMarkers: ThreadReadMarkerStore,
        projectLimit: Int,
        visibleThreadLimit: Int,
        now: Date
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
            let catalogProject = projectCatalog.project(forThreadID: thread.id, cwd: thread.cwd)
            guard shouldShowThread(thread, project: catalogProject, projectCatalog: projectCatalog, now: now) else {
                continue
            }

            let project = displayProject(
                for: thread,
                catalogProject: catalogProject,
                projectCatalog: projectCatalog
            )
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
            let orderedThreads = bucket.orderedThreads.sorted(by: isNewerThread)
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
            let allThreadSnapshots = orderedThreads.map {
                makeThreadSnapshot($0, threadReadMarkers: threadReadMarkers)
            }
            let threadSnapshotsByID = Dictionary(
                uniqueKeysWithValues: allThreadSnapshots.map { ($0.id, $0) }
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
                threads: topLevelThreads.compactMap { threadSnapshotsByID[$0.id] },
                threadGroups: threadGroups,
                allThreads: allThreadSnapshots
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

    private static func limitProjectSections(
        _ sections: [MenubarProjectSectionSnapshot],
        projectLimit: Int,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let visibleProjectLimit = max(0, projectLimit)
        let visibleThreadLimit = max(0, visibleThreadLimit)
        let orderedSections: [MenubarProjectSectionSnapshot]

        if sections.count > visibleProjectLimit {
            orderedSections = sections.sorted(by: isHigherPriorityProjectSection)
        } else {
            orderedSections = sections
        }

        let limitedSections = Array(orderedSections.prefix(visibleProjectLimit))

        return limitedSections.map { section in
            let orderedThreads: [MenubarThreadSnapshot]
            if section.threads.count > visibleThreadLimit {
                orderedThreads = prioritizedThreads(in: section)
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
                threadGroups: limitedThreadGroups,
                allThreads: section.allThreads
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

    private static func shouldShowThread(
        _ thread: AppStateStore.ThreadRow,
        project: CodexDesktopProjectCatalog.ProjectReference,
        projectCatalog: CodexDesktopProjectCatalog,
        now: Date
    ) -> Bool {
        if project.id == CodexDesktopProjectCatalog.unknownProjectID,
           !projectCatalog.workspaceRoots.isEmpty {
            return shouldKeepUnmatchedThread(thread, now: now)
        }

        if isKnownProject(project, in: projectCatalog) {
            return true
        }

        guard !projectCatalog.workspaceRoots.isEmpty else {
            return true
        }

        return shouldKeepUnmatchedThread(thread, now: now)
    }

    private static func displayProject(
        for thread: AppStateStore.ThreadRow,
        catalogProject: CodexDesktopProjectCatalog.ProjectReference,
        projectCatalog: CodexDesktopProjectCatalog
    ) -> CodexDesktopProjectCatalog.ProjectReference {
        guard catalogProject.id == CodexDesktopProjectCatalog.unknownProjectID,
              !projectCatalog.workspaceRoots.isEmpty
        else {
            return catalogProject
        }

        let normalizedCWD = CodexDesktopWorktreePath.normalize(path: thread.cwd)
        guard !normalizedCWD.isEmpty else {
            return catalogProject
        }

        return CodexDesktopProjectCatalog.ProjectReference(
            id: normalizedCWD,
            displayName: CodexDesktopWorktreePath.fallbackDisplayName(for: normalizedCWD)
        )
    }

    private static func shouldKeepUnmatchedThread(
        _ thread: AppStateStore.ThreadRow,
        now: Date
    ) -> Bool {
        thread.authoritativeListPresence == .pendingInclusion
            || now.timeIntervalSince(thread.activityUpdatedAt) <= unmatchedProjectGraceInterval
    }

    private static func isKnownProject(
        _ project: CodexDesktopProjectCatalog.ProjectReference,
        in projectCatalog: CodexDesktopProjectCatalog
    ) -> Bool {
        project.id == CodexDesktopProjectCatalog.chatsProjectID
            || projectCatalog.workspaceRoots.contains { $0.path == project.id }
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

    private static func displayedOverallStatus(
        state: AppStateStore,
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

        if state.connection.isFailed {
            return .failed
        }

        if displayedMainThreads.contains(where: { $0.presentationStatus == .failed }) {
            return .failed
        }

        return .idle
    }

    private static func makeThreadSnapshot(
        _ thread: AppStateStore.ThreadRow,
        threadReadMarkers: ThreadReadMarkerStore
    ) -> MenubarThreadSnapshot {
        MenubarThreadSnapshot(
            thread: thread,
            hasUnreadContent: threadReadMarkers.hasUnreadContent(
                threadID: thread.id,
                lastTerminalActivityAt: thread.lastTerminalActivityAt
            )
        )
    }

    private static func hasUnreadContent(in thread: ThreadMenuThread) -> Bool {
        thread.hasUnreadContent || thread.children.contains(where: hasUnreadContent)
    }

    private static func isNewerThread(_ lhs: AppStateStore.ThreadRow, _ rhs: AppStateStore.ThreadRow) -> Bool {
        if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.activityUpdatedAt > rhs.activityUpdatedAt
    }
}
