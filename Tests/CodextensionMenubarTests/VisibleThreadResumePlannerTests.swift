import XCTest
@testable import CodextensionMenubar

final class VisibleThreadResumePlannerTests: XCTestCase {
    func testThreadIDsToResumeReturnsVisibleThreadOrderExcludingAlreadyResumedIDs() {
        let sections = [
            AppStateStore.ProjectSection(
                id: "project-a",
                displayName: "A",
                latestUpdatedAt: Date(timeIntervalSince1970: 200),
                threads: [
                    threadRow(id: "thread-1", updatedAt: 200),
                    threadRow(id: "thread-2", updatedAt: 190),
                ]
            ),
            AppStateStore.ProjectSection(
                id: "project-b",
                displayName: "B",
                latestUpdatedAt: Date(timeIntervalSince1970: 180),
                threads: [
                    threadRow(id: "thread-3", updatedAt: 180),
                ]
            ),
        ]

        let threadIDs = VisibleThreadResumePlanner.threadIDsToResume(
            from: sections,
            excluding: ["thread-2"]
        )

        XCTAssertEqual(threadIDs, ["thread-1", "thread-3"])
    }

    private static func threadRow(id: String, updatedAt: TimeInterval) -> AppStateStore.ThreadRow {
        AppStateStore.ThreadRow(
            id: id,
            displayTitle: id,
            preview: id,
            cwd: "/tmp/\(id)",
            status: .idle,
            listedStatus: .idle,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            isWatched: false,
            activeTurnID: nil,
            lastTerminalActivityAt: nil
        )
    }

    private func threadRow(id: String, updatedAt: TimeInterval) -> AppStateStore.ThreadRow {
        Self.threadRow(id: id, updatedAt: updatedAt)
    }
}
