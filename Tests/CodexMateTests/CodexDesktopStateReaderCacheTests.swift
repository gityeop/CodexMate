import XCTest
@testable import CodexMate

final class CodexDesktopStateReaderCacheTests: XCTestCase {
    func testSessionPendingStateCachePrunesUntrackedPaths() {
        let cache = SessionPendingStateCache()
        let modificationDate = Date(timeIntervalSince1970: 100)

        cache.store(
            .init(
                continuation: .init(
                    unresolvedRequestUserInputCallIDs: ["call-a"]
                )
            ),
            for: "/tmp/a.jsonl",
            modificationDate: modificationDate,
            fileSize: 10
        )
        cache.store(
            .init(
                continuation: .init(
                    unresolvedApprovalCallIDs: ["call-b"]
                )
            ),
            for: "/tmp/b.jsonl",
            modificationDate: modificationDate,
            fileSize: 20
        )

        cache.prune(keepingPaths: ["/tmp/a.jsonl"])

        XCTAssertNotNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 10))
        XCTAssertNil(cache.value(for: "/tmp/b.jsonl", modificationDate: modificationDate, fileSize: 20))
    }

    func testSessionPendingStateCacheProvidesAppendCheckpointWhenFileGrows() {
        let cache = SessionPendingStateCache()
        let modificationDate = Date(timeIntervalSince1970: 100)
        let checkpoint = CodexDesktopStateReader.SessionPendingScanCheckpoint(
            continuation: .init(
                activeTaskIDs: ["turn-1"]
            )
        )

        cache.store(
            checkpoint,
            for: "/tmp/a.jsonl",
            modificationDate: modificationDate,
            fileSize: 10
        )

        XCTAssertNotNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 10))
        XCTAssertNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 11))
        let appendSource = cache.appendSource(for: "/tmp/a.jsonl", fileSize: 11)
        XCTAssertEqual(appendSource?.offset, 10)
        XCTAssertEqual(appendSource?.checkpoint, checkpoint)
    }
}
