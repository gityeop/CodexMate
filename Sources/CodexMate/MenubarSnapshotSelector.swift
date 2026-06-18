import Foundation

enum MenubarSnapshotSelector {
    private static let unmatchedProjectGraceInterval: TimeInterval = 2 * 60

    static func makeSnapshot(
        state: AppStateStore,
        projectCatalog: CodexDesktopProjectCatalog,
        threadReadMarkers: ThreadReadMarkerStore,
        threadListViewMode: ThreadListViewMode = .projects,
        pinnedThreadIDs: Set<String> = [],
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
        let allProjectSections = threadListViewMode == .projects && pinnedThreadIDs.isEmpty
            ? projectSections
            : projectSectionsWithSubagentThreads(
                state: state,
                projectCatalog: projectCatalog,
                threadReadMarkers: threadReadMarkers,
                projectLimit: .max,
                visibleThreadLimit: .max,
                now: now
            )
        let menuSnapshotSections = menuSnapshotSections(
            projectSections: projectSections,
            allProjectSections: allProjectSections,
            viewMode: threadListViewMode,
            pinnedThreadIDs: pinnedThreadIDs,
            visibleThreadLimit: visibleThreadLimit
        )
        let menuSections = ThreadMenuBuilder.build(snapshotSections: menuSnapshotSections)
        let hasVisibleSnapshotThreads = menuSnapshotSections.contains { !$0.allThreads.isEmpty }

        return MenubarSnapshot(
            overallStatus: displayedOverallStatus(
                state: state,
                snapshotSections: menuSnapshotSections
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
        let threadsByID = Dictionary(uniqueKeysWithValues: allThreads.map { ($0.id, $0) })

        for thread in allThreads {
            guard !thread.hasUnhydratedPlaceholderMetadata else {
                continue
            }

            let catalogProject = projectCatalog.project(forThreadID: thread.id, cwd: thread.cwd)
            let project = displayProjectForMenu(
                for: thread,
                threadsByID: threadsByID,
                catalogProject: catalogProject,
                projectCatalog: projectCatalog
            )
            guard shouldShowThread(thread, project: project, projectCatalog: projectCatalog, now: now) else {
                continue
            }

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

    private static func menuSnapshotSections(
        projectSections: [MenubarProjectSectionSnapshot],
        allProjectSections: [MenubarProjectSectionSnapshot],
        viewMode: ThreadListViewMode,
        pinnedThreadIDs: Set<String>,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let allThreadSnapshots = uniqueThreadSnapshots(allProjectSections.flatMap(\.allThreads))
        let pinnedSnapshots = allThreadSnapshots
            .filter { pinnedThreadIDs.contains($0.id) }
            .sorted(by: isNewerThread)
        let pinnedRootIDs = Set(pinnedSnapshots.map(\.id))
        let excludedThreadIDs = pinnedRootIDs.union(
            descendantIDs(of: pinnedRootIDs, in: allThreadSnapshots)
        )
        let pinnedSection = pinnedSnapshotSection(
            pinnedSnapshots: pinnedSnapshots,
            allThreadSnapshots: allThreadSnapshots
        )

        let baseSections: [MenubarProjectSectionSnapshot]
        switch viewMode {
        case .projects:
            baseSections = removingThreadIDs(excludedThreadIDs, from: projectSections)
        case .recent:
            baseSections = recentSnapshotSections(
                allThreadSnapshots: allThreadSnapshots,
                excludedThreadIDs: excludedThreadIDs,
                visibleThreadLimit: visibleThreadLimit
            )
        case .status:
            baseSections = statusSnapshotSections(
                allThreadSnapshots: allThreadSnapshots,
                excludedThreadIDs: excludedThreadIDs,
                visibleThreadLimit: visibleThreadLimit
            )
        }

        if let pinnedSection {
            return [pinnedSection] + baseSections
        }

        return baseSections
    }

    private static func pinnedSnapshotSection(
        pinnedSnapshots: [MenubarThreadSnapshot],
        allThreadSnapshots: [MenubarThreadSnapshot]
    ) -> MenubarProjectSectionSnapshot? {
        guard !pinnedSnapshots.isEmpty else {
            return nil
        }

        let pinnedThreadIDs = Set(pinnedSnapshots.map(\.id))
        let includedThreadIDs = pinnedThreadIDs.union(
            descendantIDs(of: pinnedThreadIDs, in: allThreadSnapshots)
        )
        let includedSnapshots = allThreadSnapshots
            .filter { includedThreadIDs.contains($0.id) }
            .sorted(by: isNewerThread)
        let rootSnapshots = visibleRootSnapshots(
            from: pinnedSnapshots,
            allThreadSnapshots: includedSnapshots
        )

        return makeSnapshotSection(
            id: "__codexmate_pinned__",
            displayName: "Pinned",
            threadSnapshots: rootSnapshots,
            allThreadSnapshots: includedSnapshots
        )
    }

    private static func recentSnapshotSections(
        allThreadSnapshots: [MenubarThreadSnapshot],
        excludedThreadIDs: Set<String>,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let limit = max(0, visibleThreadLimit)
        let rootSnapshots = allThreadSnapshots
            .filter { !excludedThreadIDs.contains($0.id) && !$0.thread.isSubagent }
            .sorted(by: isNewerThread)
        let limitedRootSnapshots = Array(rootSnapshots.prefix(limit))
        let rootThreadIDs = Set(limitedRootSnapshots.map(\.id))
        let includedThreadIDs = rootThreadIDs
            .union(descendantIDs(of: rootThreadIDs, in: allThreadSnapshots))
            .subtracting(excludedThreadIDs)
        let includedSnapshots = allThreadSnapshots
            .filter { includedThreadIDs.contains($0.id) }
            .sorted(by: isNewerThread)

        return makeSnapshotSection(
            id: "__codexmate_recent__",
            displayName: "Recent",
            threadSnapshots: limitedRootSnapshots,
            allThreadSnapshots: includedSnapshots
        ).map { [$0] } ?? []
    }

    private static func statusSnapshotSections(
        allThreadSnapshots: [MenubarThreadSnapshot],
        excludedThreadIDs: Set<String>,
        visibleThreadLimit: Int
    ) -> [MenubarProjectSectionSnapshot] {
        let limit = max(0, visibleThreadLimit)
        let availableSnapshots = allThreadSnapshots.filter { !excludedThreadIDs.contains($0.id) }
        var assignedThreadIDs: Set<String> = []
        var sections: [MenubarProjectSectionSnapshot] = []

        func appendSection(
            id: String,
            displayName: String,
            candidates: [MenubarThreadSnapshot]
        ) {
            let unassignedCandidates = candidates.filter { !assignedThreadIDs.contains($0.id) }
            assignedThreadIDs.formUnion(unassignedCandidates.map(\.id))
            let rootSnapshots = Array(
                visibleRootSnapshots(
                    from: unassignedCandidates,
                    allThreadSnapshots: unassignedCandidates
                ).prefix(limit)
            )
            let rootThreadIDs = Set(rootSnapshots.map(\.id))
            let includedThreadIDs = rootThreadIDs.union(
                descendantIDs(of: rootThreadIDs, in: unassignedCandidates)
            )
            let includedSnapshots = unassignedCandidates
                .filter { includedThreadIDs.contains($0.id) }
                .sorted(by: isNewerThread)

            if let section = makeSnapshotSection(
                id: id,
                displayName: displayName,
                threadSnapshots: rootSnapshots,
                allThreadSnapshots: includedSnapshots
            ) {
                sections.append(section)
            }
        }

        appendSection(
            id: "__codexmate_status_wait__",
            displayName: "Wait",
            candidates: availableSnapshots.filter { $0.thread.presentationStatus == .waitingForUser }
        )
        appendSection(
            id: "__codexmate_status_running__",
            displayName: "Running",
            candidates: availableSnapshots.filter { $0.thread.presentationStatus == .running }
        )
        appendSection(
            id: "__codexmate_status_unread__",
            displayName: "Unread",
            candidates: availableSnapshots.filter { $0.hasUnreadContent }
        )

        let otherCandidates = availableSnapshots.filter {
            !assignedThreadIDs.contains($0.id) && !$0.thread.isSubagent
        }
        let otherRootSnapshots = Array(otherCandidates.sorted(by: isNewerThread).prefix(limit))
        let otherRootThreadIDs = Set(otherRootSnapshots.map(\.id))
        let otherIncludedThreadIDs = otherRootThreadIDs.union(
            descendantIDs(of: otherRootThreadIDs, in: availableSnapshots)
        )
        let otherIncludedSnapshots = availableSnapshots
            .filter { otherIncludedThreadIDs.contains($0.id) && !assignedThreadIDs.contains($0.id) }
            .sorted(by: isNewerThread)

        if let otherSection = makeSnapshotSection(
            id: "__codexmate_status_other__",
            displayName: "Other",
            threadSnapshots: otherRootSnapshots,
            allThreadSnapshots: otherIncludedSnapshots
        ) {
            sections.append(otherSection)
        }

        return sections
    }

    private static func removingThreadIDs(
        _ threadIDs: Set<String>,
        from sections: [MenubarProjectSectionSnapshot]
    ) -> [MenubarProjectSectionSnapshot] {
        guard !threadIDs.isEmpty else {
            return sections
        }

        return sections.compactMap { section in
            makeSnapshotSection(
                id: section.id,
                displayName: section.section.displayName,
                threadSnapshots: section.threads.filter { !threadIDs.contains($0.id) },
                allThreadSnapshots: section.allThreads.filter { !threadIDs.contains($0.id) }
            )
        }
    }

    private static func makeSnapshotSection(
        id: String,
        displayName: String,
        threadSnapshots: [MenubarThreadSnapshot],
        allThreadSnapshots: [MenubarThreadSnapshot]
    ) -> MenubarProjectSectionSnapshot? {
        guard !allThreadSnapshots.isEmpty else {
            return nil
        }

        let latestUpdatedAt = allThreadSnapshots
            .map(\.thread.activityUpdatedAt)
            .max() ?? .distantPast

        return MenubarProjectSectionSnapshot(
            section: AppStateStore.ProjectSection(
                id: id,
                displayName: displayName,
                latestUpdatedAt: latestUpdatedAt,
                threads: threadSnapshots.map(\.thread)
            ),
            threads: threadSnapshots,
            threadGroups: [],
            allThreads: allThreadSnapshots
        )
    }

    private static func visibleRootSnapshots(
        from snapshots: [MenubarThreadSnapshot],
        allThreadSnapshots: [MenubarThreadSnapshot]
    ) -> [MenubarThreadSnapshot] {
        let candidateThreadIDs = Set(snapshots.map(\.id))
        let parentIDByThreadID = Dictionary(
            uniqueKeysWithValues: allThreadSnapshots.compactMap { snapshot in
                snapshot.thread.parentThreadID.map { (snapshot.id, $0) }
            }
        )

        return snapshots.filter { snapshot in
            !threadHasAncestor(
                snapshot.id,
                in: candidateThreadIDs,
                parentIDByThreadID: parentIDByThreadID
            )
        }
        .sorted(by: isNewerThread)
    }

    private static func descendantIDs(
        of rootThreadIDs: Set<String>,
        in snapshots: [MenubarThreadSnapshot]
    ) -> Set<String> {
        guard !rootThreadIDs.isEmpty else {
            return []
        }

        var descendants: Set<String> = []
        var didAddDescendant = true

        while didAddDescendant {
            didAddDescendant = false

            for snapshot in snapshots {
                guard !rootThreadIDs.contains(snapshot.id),
                      !descendants.contains(snapshot.id),
                      let parentThreadID = snapshot.thread.parentThreadID,
                      rootThreadIDs.contains(parentThreadID) || descendants.contains(parentThreadID)
                else {
                    continue
                }

                descendants.insert(snapshot.id)
                didAddDescendant = true
            }
        }

        return descendants
    }

    private static func threadHasAncestor(
        _ threadID: String,
        in ancestorIDs: Set<String>,
        parentIDByThreadID: [String: String]
    ) -> Bool {
        var currentThreadID = parentIDByThreadID[threadID]
        var visited: Set<String> = [threadID]

        while let parentThreadID = currentThreadID {
            if !visited.insert(parentThreadID).inserted {
                return false
            }

            if ancestorIDs.contains(parentThreadID) {
                return true
            }

            currentThreadID = parentIDByThreadID[parentThreadID]
        }

        return false
    }

    private static func uniqueThreadSnapshots(
        _ snapshots: [MenubarThreadSnapshot]
    ) -> [MenubarThreadSnapshot] {
        var seenThreadIDs: Set<String> = []
        var uniqueSnapshots: [MenubarThreadSnapshot] = []

        for snapshot in snapshots where seenThreadIDs.insert(snapshot.id).inserted {
            uniqueSnapshots.append(snapshot)
        }

        return uniqueSnapshots
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
            displayName: CodexDesktopWorktreePath.inferredDisplayName(for: normalizedCWD)
        )
    }

    private static func displayProjectForMenu(
        for thread: AppStateStore.ThreadRow,
        threadsByID: [String: AppStateStore.ThreadRow],
        catalogProject: CodexDesktopProjectCatalog.ProjectReference,
        projectCatalog: CodexDesktopProjectCatalog
    ) -> CodexDesktopProjectCatalog.ProjectReference {
        guard let parentThreadID = thread.parentThreadID,
              let parentThread = threadsByID[parentThreadID]
        else {
            return displayProject(
                for: thread,
                catalogProject: catalogProject,
                projectCatalog: projectCatalog
            )
        }

        let parentCatalogProject = projectCatalog.project(
            forThreadID: parentThread.id,
            cwd: parentThread.cwd
        )
        return displayProject(
            for: parentThread,
            catalogProject: parentCatalogProject,
            projectCatalog: projectCatalog
        )
    }

    private static func shouldKeepUnmatchedThread(
        _ thread: AppStateStore.ThreadRow,
        now: Date
    ) -> Bool {
        thread.authoritativeListPresence == .pendingInclusion
            || shouldKeepListedUnmatchedThread(thread)
            || now.timeIntervalSince(thread.activityUpdatedAt) <= unmatchedProjectGraceInterval
    }

    private static func shouldKeepListedUnmatchedThread(_ thread: AppStateStore.ThreadRow) -> Bool {
        guard thread.authoritativeListPresence == .listed else {
            return false
        }

        let normalizedCWD = CodexDesktopWorktreePath.normalize(path: thread.cwd)
        guard !normalizedCWD.isEmpty else {
            return false
        }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: normalizedCWD, isDirectory: &isDirectory)
            && isDirectory.boolValue
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

    private static func isNewerThread(_ lhs: MenubarThreadSnapshot, _ rhs: MenubarThreadSnapshot) -> Bool {
        isNewerThread(lhs.thread, rhs.thread)
    }
}
