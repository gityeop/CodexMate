import XCTest
@testable import CodextensionMenubar

final class CodexDesktopStateReaderCacheTests: XCTestCase {
    func testSessionPendingStateCachePrunesUntrackedPaths() {
        let cache = SessionPendingStateCache()
        let modificationDate = Date(timeIntervalSince1970: 100)

        cache.store(
            .init(waitingForInput: true, needsApproval: false),
            for: "/tmp/a.jsonl",
            modificationDate: modificationDate,
            fileSize: 10
        )
        cache.store(
            .init(waitingForInput: false, needsApproval: true),
            for: "/tmp/b.jsonl",
            modificationDate: modificationDate,
            fileSize: 20
        )

        cache.prune(keepingPaths: ["/tmp/a.jsonl"])

        XCTAssertNotNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 10))
        XCTAssertNil(cache.value(for: "/tmp/b.jsonl", modificationDate: modificationDate, fileSize: 20))
    }

    func testSessionPendingStateCacheInvalidatesWhenFileSizeChanges() {
        let cache = SessionPendingStateCache()
        let modificationDate = Date(timeIntervalSince1970: 100)

        cache.store(
            .init(waitingForInput: true, needsApproval: false),
            for: "/tmp/a.jsonl",
            modificationDate: modificationDate,
            fileSize: 10
        )

        XCTAssertNotNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 10))
        XCTAssertNil(cache.value(for: "/tmp/a.jsonl", modificationDate: modificationDate, fileSize: 11))
    }
}
