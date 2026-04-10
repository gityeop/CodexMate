import Foundation

struct ThreadMenuSection: Equatable {
    let displayName: String
    let threadCount: Int
    let threads: [ThreadMenuThread]
}

struct ThreadMenuThread: Equatable {
    let thread: AppStateStore.ThreadRow
    let hasUnreadContent: Bool
    let children: [ThreadMenuThread]
}

enum ThreadMenuBuilder {
    static func build(
        snapshotSections: [MenubarProjectSectionSnapshot]
    ) -> [ThreadMenuSection] {
        return snapshotSections.compactMap { snapshotSection -> ThreadMenuSection? in
            return buildSection(
                displayName: snapshotSection.section.displayName,
                sectionThreads: snapshotSection.allThreads,
                visibleRootIDs: Set(snapshotSection.threads.map(\.id))
            )
        }
    }

    private static func buildSection(
        displayName: String,
        sectionThreads: [MenubarThreadSnapshot],
        visibleRootIDs: Set<String>?
    ) -> ThreadMenuSection? {
        guard !sectionThreads.isEmpty else { return nil }

        let parentIDByThreadID = Dictionary(
            uniqueKeysWithValues: sectionThreads.compactMap { thread in
                thread.thread.parentThreadID.map { (thread.id, $0) }
            }
        )
        let roots = sectionRootThreads(
            allThreads: sectionThreads,
            visibleRootIDs: visibleRootIDs,
            parentIDByThreadID: parentIDByThreadID
        )
        let childrenByParentID = Dictionary(grouping: sectionThreads) { $0.thread.parentThreadID }
        let rootNodes = roots.compactMap { root in
            buildThread(
                thread: root,
                childrenByParentID: childrenByParentID,
                isRoot: true,
                visited: []
            )
        }
        .sorted(by: isHigherPriorityMenuThread)
        guard !rootNodes.isEmpty else { return nil }

        return ThreadMenuSection(
            displayName: displayName,
            threadCount: rootNodes.count,
            threads: rootNodes
        )
    }

    private static func buildThread(
        thread: MenubarThreadSnapshot,
        childrenByParentID: [String?: [MenubarThreadSnapshot]],
        isRoot: Bool,
        visited: Set<String>
    ) -> ThreadMenuThread? {
        guard !visited.contains(thread.id) else {
            return nil
        }

        let childThreads = (childrenByParentID[thread.id] ?? []).sorted(by: isNewerThread)
        let nextVisited = visited.union([thread.id])

        let visibleChildren = childThreads.compactMap { child in
            buildThread(
                thread: child,
                childrenByParentID: childrenByParentID,
                isRoot: false,
                visited: nextVisited
            )
        }

        let shouldShow = isRoot || isAttentionThread(thread.thread) || !visibleChildren.isEmpty
        guard shouldShow else {
            return nil
        }

        let sortedVisibleChildren = visibleChildren.sorted(by: isHigherPriorityMenuThread)
        return ThreadMenuThread(
            thread: thread.thread,
            hasUnreadContent: thread.hasUnreadContent,
            children: sortedVisibleChildren
        )
    }

    private static func sectionRootThreads(
        allThreads: [MenubarThreadSnapshot],
        visibleRootIDs: Set<String>?,
        parentIDByThreadID: [String: String]
    ) -> [MenubarThreadSnapshot] {
        let threadByID = Dictionary(uniqueKeysWithValues: allThreads.map { ($0.id, $0) })
        let allThreadIDs = Set(allThreads.map(\.id))

        if let visibleRootIDs, !visibleRootIDs.isEmpty {
            var roots = allThreads.filter { visibleRootIDs.contains($0.id) }
            let orphanThreads = allThreads.filter { thread in
                guard thread.thread.isSubagent else {
                    return false
                }

                guard isAttentionThread(thread.thread) else {
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
            thread.children.map(menuVisibilityPriority).max() ?? 0
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
