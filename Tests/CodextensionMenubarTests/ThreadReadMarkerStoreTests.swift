import XCTest
@testable import CodextensionMenubar

final class ThreadReadMarkerStoreTests: XCTestCase {
    func testSeededThreadWithoutTerminalActivityStartsReadUntilTerminalUpdateArrives() {
        var store = ThreadReadMarkerStore()
        let terminalUpdatedAt = Date(timeIntervalSince1970: 120)

        XCTAssertTrue(store.seedIfNeeded(threadID: "thread-1"))
        XCTAssertFalse(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: nil))
        XCTAssertTrue(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: terminalUpdatedAt))
    }

    func testSeededThreadWithExistingTerminalActivityStartsUnreadUntilOpened() {
        var store = ThreadReadMarkerStore()
        let terminalUpdatedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(store.seedIfNeeded(threadID: "thread-1"))
        XCTAssertTrue(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: terminalUpdatedAt))
    }

    func testMarkReadClearsUnreadAndDoesNotMoveBackward() {
        var store = ThreadReadMarkerStore(lastReadTerminalAtByThreadID: ["thread-1": 100])
        let newerTerminalAt = Date(timeIntervalSince1970: 120)

        XCTAssertTrue(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: newerTerminalAt))
        XCTAssertTrue(store.markRead(threadID: "thread-1", lastTerminalActivityAt: newerTerminalAt))
        XCTAssertFalse(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: newerTerminalAt))
        XCTAssertFalse(store.markRead(threadID: "thread-1", lastTerminalActivityAt: Date(timeIntervalSince1970: 110)))
        XCTAssertFalse(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: Date(timeIntervalSince1970: 115)))
    }

    func testMarkReadIfViewedAfterLastTerminalActivityClearsUnread() {
        var store = ThreadReadMarkerStore()
        let terminalUpdatedAt = Date(timeIntervalSince1970: 120)
        let viewedAt = Date(timeIntervalSince1970: 130)

        XCTAssertTrue(
            store.markReadIfViewedAfterLastTerminalActivity(
                threadID: "thread-1",
                lastTerminalActivityAt: terminalUpdatedAt,
                viewedAt: viewedAt
            )
        )
        XCTAssertFalse(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: terminalUpdatedAt))
    }

    func testMarkReadIfViewedAfterLastTerminalActivityIgnoresOlderView() {
        var store = ThreadReadMarkerStore()
        let terminalUpdatedAt = Date(timeIntervalSince1970: 120)
        let viewedAt = Date(timeIntervalSince1970: 110)

        XCTAssertFalse(
            store.markReadIfViewedAfterLastTerminalActivity(
                threadID: "thread-1",
                lastTerminalActivityAt: terminalUpdatedAt,
                viewedAt: viewedAt
            )
        )
        XCTAssertTrue(store.hasUnreadContent(threadID: "thread-1", lastTerminalActivityAt: terminalUpdatedAt))
    }

    func testPruneKeepsTrackedThreadsAndRecentEntriesOnly() {
        var store = ThreadReadMarkerStore(
            lastReadTerminalAtByThreadID: [
                "recent-thread": 500,
                "tracked-thread": 0,
                "stale-thread": 100,
            ]
        )

        XCTAssertTrue(
            store.prune(
                keeping: ["tracked-thread"],
                minimumTimestamp: 400
            )
        )
        XCTAssertEqual(
            store.lastReadTerminalAtByThreadID,
            [
                "recent-thread": 500,
                "tracked-thread": 0,
            ]
        )
    }
}
