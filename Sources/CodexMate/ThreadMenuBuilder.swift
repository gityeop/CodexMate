import Foundation

struct ThreadMenuSection: Equatable {
    let displayName: String
    let threadCount: Int
    let threads: [ThreadMenuThread]
}

struct ThreadMenuThread: Equatable {
    let thread: AppStateStore.ThreadRow
    let children: [ThreadMenuThread]
    let hiddenSubagentSummary: MenubarStatusPresentation.SubagentSummary?
    let hiddenDescendantThreads: [AppStateStore.ThreadRow]

    init(
        thread: AppStateStore.ThreadRow,
        children: [ThreadMenuThread],
        hiddenSubagentSummary: MenubarStatusPresentation.SubagentSummary? = nil,
        hiddenDescendantThreads: [AppStateStore.ThreadRow] = []
    ) {
        self.thread = thread
        self.children = children
        self.hiddenSubagentSummary = hiddenSubagentSummary
        self.hiddenDescendantThreads = hiddenDescendantThreads
    }
}

enum ThreadMenuBuilder {
    static func build(
        snapshotSections: [MenubarProjectSectionSnapshot],
        recentThreads: [AppStateStore.ThreadRow],
        projectCatalog: CodexDesktopProjectCatalog,
        projectLimit: Int? = nil,
        visibleThreadLimit: Int? = nil
    ) -> [ThreadMenuSection] {
        let parentIDByThreadID = Dictionary(
            uniqueKeysWithValues: recentThreads.compactMap { thread in
                thread.parentThreadID.map { (thread.id, $0) }
            }
        )

        if snapshotSections.isEmpty {
            struct FallbackSection {
                let displayName: String
                let latestUpdatedAt: Date
                let threads: [AppStateStore.ThreadRow]
            }

            let sectionsByProjectID = Dictionary(grouping: recentThreads) { thread in
                projectCatalog.project(for: thread.cwd).id
            }
            let fallbackSections = sectionsByProjectID.values.compactMap { sectionThreads -> FallbackSection? in
                guard let firstThread = sectionThreads.first else { return nil }
                let project = projectCatalog.project(for: firstThread.cwd)
                return FallbackSection(
                    displayName: project.displayName,
                    latestUpdatedAt: sectionThreads.map(\.activityUpdatedAt).max() ?? .distantPast,
                    threads: sectionThreads
                )
            }
            .sorted { lhs, rhs in
                if lhs.latestUpdatedAt == rhs.latestUpdatedAt {
                    return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                }

                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
            }

            let limitedFallbackSections: ArraySlice<FallbackSection>
            if let projectLimit {
                limitedFallbackSections = fallbackSections.prefix(max(0, projectLimit))
            } else {
                limitedFallbackSections = fallbackSections[...]
            }

            return limitedFallbackSections.compactMap { section -> ThreadMenuSection? in
                return buildSection(
                    displayName: section.displayName,
                    sectionThreads: section.threads,
                    visibleRootIDs: nil,
                    parentIDByThreadID: parentIDByThreadID,
                    visibleRootLimit: visibleThreadLimit
                )
            }
        }

        return snapshotSections.compactMap { snapshotSection -> ThreadMenuSection? in
            let sectionThreads = recentThreads.filter {
                projectCatalog.project(for: $0.cwd).id == snapshotSection.section.id
            }

            guard !sectionThreads.isEmpty else {
                return nil
            }

            return buildSection(
                displayName: snapshotSection.section.displayName,
                sectionThreads: sectionThreads,
                visibleRootIDs: Set(snapshotSection.threads.map(\.id)),
                parentIDByThreadID: parentIDByThreadID,
                visibleRootLimit: nil
            )
        }
    }

    private static func buildSection(
        displayName: String,
        sectionThreads: [AppStateStore.ThreadRow],
        visibleRootIDs: Set<String>?,
        parentIDByThreadID: [String: String],
        visibleRootLimit: Int?
    ) -> ThreadMenuSection {
        let roots = sectionRootThreads(
            allThreads: sectionThreads,
            visibleRootIDs: visibleRootIDs,
            parentIDByThreadID: parentIDByThreadID
        )
        let childrenByParentID = Dictionary(grouping: sectionThreads) { $0.parentThreadID }
        let rootNodes = roots.compactMap { root in
            buildThread(
                thread: root,
                childrenByParentID: childrenByParentID,
                isRoot: true,
                visited: []
            ).node
        }
        .sorted(by: isHigherPriorityMenuThread)
        let visibleRootNodes: [ThreadMenuThread]
        if let visibleRootLimit {
            visibleRootNodes = Array(rootNodes.prefix(max(0, visibleRootLimit)))
        } else {
            visibleRootNodes = rootNodes
        }

        return ThreadMenuSection(
            displayName: displayName,
            threadCount: visibleRootNodes.count,
            threads: visibleRootNodes
        )
    }

    private struct BuildOutcome {
        let node: ThreadMenuThread?
        let allDescendants: [AppStateStore.ThreadRow]
    }

    private static func buildThread(
        thread: AppStateStore.ThreadRow,
        childrenByParentID: [String?: [AppStateStore.ThreadRow]],
        isRoot: Bool,
        visited: Set<String>
    ) -> BuildOutcome {
        guard !visited.contains(thread.id) else {
            return BuildOutcome(node: nil, allDescendants: [])
        }

        let childThreads = (childrenByParentID[thread.id] ?? []).sorted(by: isNewerThread)
        let nextVisited = visited.union([thread.id])

        var visibleChildren: [ThreadMenuThread] = []
        var hiddenDescendants: [AppStateStore.ThreadRow] = []
        var allDescendants: [AppStateStore.ThreadRow] = []

        for child in childThreads {
            let outcome = buildThread(
                thread: child,
                childrenByParentID: childrenByParentID,
                isRoot: false,
                visited: nextVisited
            )
            allDescendants.append(child)
            allDescendants.append(contentsOf: outcome.allDescendants)

            if let node = outcome.node {
                visibleChildren.append(node)
                hiddenDescendants.append(contentsOf: node.hiddenDescendantThreads)
            } else {
                hiddenDescendants.append(child)
                hiddenDescendants.append(contentsOf: outcome.allDescendants)
            }
        }

        let shouldShow = isRoot || isAttentionThread(thread) || !visibleChildren.isEmpty
        guard shouldShow else {
            return BuildOutcome(node: nil, allDescendants: allDescendants)
        }

        let sortedVisibleChildren = visibleChildren.sorted(by: isHigherPriorityMenuThread)

        return BuildOutcome(
            node: ThreadMenuThread(
                thread: thread,
                children: sortedVisibleChildren,
                hiddenSubagentSummary: MenubarStatusPresentation.SubagentSummary(hiddenThreads: hiddenDescendants),
                hiddenDescendantThreads: hiddenDescendants
            ),
            allDescendants: allDescendants
        )
    }

    private static func sectionRootThreads(
        allThreads: [AppStateStore.ThreadRow],
        visibleRootIDs: Set<String>?,
        parentIDByThreadID: [String: String]
    ) -> [AppStateStore.ThreadRow] {
        let threadByID = Dictionary(uniqueKeysWithValues: allThreads.map { ($0.id, $0) })
        let allThreadIDs = Set(allThreads.map(\.id))

        if let visibleRootIDs, !visibleRootIDs.isEmpty {
            var roots = allThreads.filter { visibleRootIDs.contains($0.id) }
            let orphanThreads = allThreads.filter { thread in
                guard thread.isSubagent else {
                    return false
                }

                guard isAttentionThread(thread) else {
                    return false
                }

                return !threadHasAncestor(
                    thread.id,
                    in: allThreadIDs,
                    parentIDByThreadID: parentIDByThreadID
                )
            }
            roots.append(contentsOf: orphanThreads.filter { !visibleRootIDs.contains($0.id) })
            return roots.sorted(by: isNewerThread)
        }

        return allThreads.filter { thread in
            guard let parentID = parentIDByThreadID[thread.id] else {
                return true
            }

            return threadByID[parentID] == nil
        }
        .sorted(by: isNewerThread)
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

    private static func flattenedThreadIDs(from threads: [ThreadMenuThread]) -> [String] {
        threads.flatMap { thread in
            [thread.thread.id] + flattenedThreadIDs(from: thread.children)
        }
    }

    private static func isAttentionThread(_ thread: AppStateStore.ThreadRow) -> Bool {
        switch thread.presentationStatus {
        case .waitingForUser, .failed:
            return true
        case .notLoaded, .idle, .running:
            return false
        }
    }

    private static func isHigherPriorityMenuThread(_ lhs: ThreadMenuThread, _ rhs: ThreadMenuThread) -> Bool {
        let lhsRank = menuVisibilityPriority(for: lhs)
        let rhsRank = menuVisibilityPriority(for: rhs)

        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        return isNewerThread(lhs.thread, rhs.thread)
    }

    private static func menuVisibilityPriority(for thread: ThreadMenuThread) -> Int {
        max(
            visibilityPriority(for: thread.thread),
            thread.children.map(menuVisibilityPriority).max() ?? 0,
            visibilityPriority(for: thread.hiddenSubagentSummary)
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
        case .notLoaded, .idle:
            return 0
        }
    }

    private static func visibilityPriority(
        for summary: MenubarStatusPresentation.SubagentSummary?
    ) -> Int {
        guard let summary else { return 0 }

        if summary.approvalCount > 0 || summary.waitingCount > 0 {
            return 3
        }

        if summary.runningCount > 0 {
            return 2
        }

        if summary.failedCount > 0 {
            return 1
        }

        return 0
    }

    private static func isNewerThread(_ lhs: AppStateStore.ThreadRow, _ rhs: AppStateStore.ThreadRow) -> Bool {
        if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.activityUpdatedAt > rhs.activityUpdatedAt
    }
}
