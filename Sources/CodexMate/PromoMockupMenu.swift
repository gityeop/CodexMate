import Foundation

enum PromoMockupMenu {
    static func statusSnapshot() -> MenubarStatusSnapshot {
        MenubarStatusSnapshot(
            overallStatus: .waitingForUser,
            hasUnreadThreads: true
        )
    }

    static func preparedSnapshot(now: Date = Date()) -> MenubarPreparedSnapshot {
        let sections = projectSpecs.enumerated().map { projectIndex, project in
            makeSection(project: project, projectIndex: projectIndex, now: now)
        }

        return MenubarPreparedSnapshot(
            snapshot: MenubarSnapshot(
                overallStatus: statusSnapshot().overallStatus,
                hasUnreadThreads: statusSnapshot().hasUnreadThreads,
                projectSections: [],
                menuSections: sections,
                hasRecentThreads: true,
                isWatchLatestThreadEnabled: false
            ),
            didChangeReadMarkers: false
        )
    }

    private struct ProjectSpec {
        let displayName: String
        let threads: [ThreadSpec]
    }

    private struct ThreadSpec {
        let title: String
        let status: AppStateStore.ThreadStatus
        let hasUnreadContent: Bool
    }

    private static let projectSpecs: [ProjectSpec] = [
        ProjectSpec(
            displayName: "CodexMate",
            threads: [
                ThreadSpec(
                    title: "Polish the final launch video scene",
                    status: .waitingForInput,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Tune notch menu expansion timing",
                    status: .running,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Review download link badge copy",
                    status: .idle,
                    hasUnreadContent: false
                )
            ]
        ),
        ProjectSpec(
            displayName: "FlowClip",
            threads: [
                ThreadSpec(
                    title: "Improve clipboard history search speed",
                    status: .idle,
                    hasUnreadContent: true
                ),
                ThreadSpec(
                    title: "Draft release notes for the next build",
                    status: .idle,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Check Sparkle update feed path",
                    status: .idle,
                    hasUnreadContent: false
                )
            ]
        ),
        ProjectSpec(
            displayName: "NoAjar",
            threads: [
                ThreadSpec(
                    title: "Test lid-close behavior after sleep",
                    status: .idle,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Review temperature logs from overnight run",
                    status: .idle,
                    hasUnreadContent: true
                ),
                ThreadSpec(
                    title: "Refine menu bar toggle accessibility",
                    status: .idle,
                    hasUnreadContent: false
                )
            ]
        ),
        ProjectSpec(
            displayName: "OnText",
            threads: [
                ThreadSpec(
                    title: "Recheck SEO color contrast",
                    status: .idle,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Find the right PopClip shortcut flow",
                    status: .idle,
                    hasUnreadContent: false
                ),
                ThreadSpec(
                    title: "Update Reddit launch post copy",
                    status: .idle,
                    hasUnreadContent: false
                )
            ]
        )
    ]

    private static func makeSection(
        project: ProjectSpec,
        projectIndex: Int,
        now: Date
    ) -> ThreadMenuSection {
        let threads = project.threads.enumerated().map { threadIndex, thread in
            ThreadMenuThread(
                thread: makeThread(
                    project: project,
                    projectIndex: projectIndex,
                    thread: thread,
                    threadIndex: threadIndex,
                    now: now
                ),
                hasUnreadContent: thread.hasUnreadContent,
                children: []
            )
        }

        return ThreadMenuSection(
            displayName: project.displayName,
            threadCount: threads.count,
            threads: threads
        )
    }

    private static func makeThread(
        project: ProjectSpec,
        projectIndex: Int,
        thread: ThreadSpec,
        threadIndex: Int,
        now: Date
    ) -> AppStateStore.ThreadRow {
        let threadID = "promo-\(project.displayName.lowercased())-\(threadIndex + 1)"
        let updatedAt = now.addingTimeInterval(-TimeInterval((projectIndex * 3 + threadIndex + 1) * 70))

        return AppStateStore.ThreadRow(
            id: threadID,
            displayTitle: thread.title,
            preview: thread.title,
            cwd: "/tmp/\(project.displayName)",
            status: thread.status,
            listedStatus: thread.status,
            updatedAt: updatedAt,
            isWatched: true,
            activeTurnID: thread.status == .running ? "promo-turn-\(threadID)" : nil,
            lastTerminalActivityAt: updatedAt
        )
    }
}
