import XCTest
@testable import CodexMate

final class PromoMockupMenuTests: XCTestCase {
    func testPreparedSnapshotContainsPromoProjectsInRequestedOrder() {
        let snapshot = PromoMockupMenu.preparedSnapshot(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).snapshot

        XCTAssertEqual(
            snapshot.menuSections.map(\.displayName),
            ["CodexMate", "FlowClip", "NoAjar", "OnText"]
        )
        XCTAssertEqual(snapshot.menuSections.map(\.threadCount), [3, 3, 3, 3])
        XCTAssertEqual(snapshot.menuSections[0].threads.map(\.thread.displayTitle), [
            "Polish the final launch video scene",
            "Tune notch menu expansion timing",
            "Review download link badge copy"
        ])
    }

    func testPreparedSnapshotPreservesPromoThreadIndicators() {
        let snapshot = PromoMockupMenu.preparedSnapshot(
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ).snapshot

        XCTAssertEqual(snapshot.overallStatus, .waitingForUser)
        XCTAssertTrue(snapshot.hasUnreadThreads)
        XCTAssertEqual(snapshot.menuSections[0].threads[0].thread.presentationStatus, .waitingForUser)
        XCTAssertEqual(snapshot.menuSections[0].threads[1].thread.presentationStatus, .running)
        XCTAssertTrue(snapshot.menuSections[1].threads[0].hasUnreadContent)
        XCTAssertTrue(snapshot.menuSections[2].threads[1].hasUnreadContent)
    }
}
