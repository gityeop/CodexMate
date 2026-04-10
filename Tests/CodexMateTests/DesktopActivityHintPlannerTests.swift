import XCTest
@testable import CodexMate

final class DesktopActivityHintPlannerTests: XCTestCase {
    func testHintLifetimesDifferentiateRunningAndCompletedTurns() {
        let now = Date(timeIntervalSince1970: 200)
        let snapshot = CodexDesktopConversationActivityReader.ActivitySnapshot(
            latestViewedAtByThreadID: [:],
            latestTurnStartedAtByThreadID: [
                "thread-1": Date(timeIntervalSince1970: 170),
                "thread-2": Date(timeIntervalSince1970: 188),
            ],
            latestTurnCompletedAtByThreadID: [
                "thread-1": Date(timeIntervalSince1970: 180)
            ]
        )

        let completionHints = DesktopActivityHintPlanner.latestTurnCompletedAtByThreadID(
            activitySnapshot: snapshot,
            candidateThreadIDs: ["thread-1"],
            now: now,
            completionHintInterval: 30 * 60
        )
        let runningHints = DesktopActivityHintPlanner.hintedRunningThreadIDs(
            activitySnapshot: snapshot,
            candidateThreadIDs: ["thread-1", "thread-2"],
            now: now,
            runningHintInterval: 15
        )

        XCTAssertEqual(completionHints["thread-1"], Date(timeIntervalSince1970: 180))
        XCTAssertEqual(runningHints, ["thread-2"])
    }
}
