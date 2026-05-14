import XCTest
@testable import CodexMate

final class PendingDiscoveredThreadStoreTests: XCTestCase {
    func testObserveReturnsOnlyNewPendingThreads() {
        var store = PendingDiscoveredThreadStore(maxTrackedThreads: 4, ttl: 60)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(store.observe(["thread-1", "thread-2"], now: now), ["thread-1", "thread-2"])
        XCTAssertEqual(store.observe(["thread-2", "thread-3"], now: now), ["thread-3"])
    }

    func testResolveRemovesFetchedThreadsButKeepsMissingOnes() {
        var store = PendingDiscoveredThreadStore(maxTrackedThreads: 4, ttl: 60)
        let now = Date(timeIntervalSince1970: 100)
        _ = store.observe(["thread-1", "thread-2"], now: now)

        let resolution = store.resolve(with: ["thread-2"], now: now)

        XCTAssertEqual(resolution.resolvedThreadIDs, ["thread-2"])
        XCTAssertEqual(resolution.missingThreadIDs, ["thread-1"])
        XCTAssertEqual(store.pendingThreadIDs, ["thread-1"])
    }

    func testPruneExpiresOldPendingThreads() {
        var store = PendingDiscoveredThreadStore(maxTrackedThreads: 4, ttl: 60)
        _ = store.observe(["thread-1"], now: Date(timeIntervalSince1970: 100))

        store.prune(now: Date(timeIntervalSince1970: 161))

        XCTAssertFalse(store.hasPendingThreads)
    }

    func testObserveTrimsToNewestBudget() {
        var store = PendingDiscoveredThreadStore(maxTrackedThreads: 2, ttl: 60)
        _ = store.observe(["thread-1"], now: Date(timeIntervalSince1970: 100))
        _ = store.observe(["thread-2"], now: Date(timeIntervalSince1970: 101))
        _ = store.observe(["thread-3"], now: Date(timeIntervalSince1970: 102))

        XCTAssertEqual(store.pendingThreadIDs, ["thread-2", "thread-3"])
    }

    func testRetryBackoffDelaysRepeatedMissingThreadLookups() {
        var store = PendingDiscoveredThreadStore(
            maxTrackedThreads: 4,
            ttl: 120,
            retryBackoffIntervals: [10, 20]
        )
        _ = store.observe(["thread-1"], now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            store.threadIDsReadyToRetry(["thread-1"], now: Date(timeIntervalSince1970: 100)),
            ["thread-1"]
        )

        store.recordRetryAttempt(for: ["thread-1"], now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(
            store.threadIDsReadyToRetry(["thread-1"], now: Date(timeIntervalSince1970: 109)),
            []
        )
        XCTAssertEqual(
            store.threadIDsReadyToRetry(["thread-1"], now: Date(timeIntervalSince1970: 110)),
            ["thread-1"]
        )

        store.recordRetryAttempt(for: ["thread-1"], now: Date(timeIntervalSince1970: 110))
        XCTAssertEqual(
            store.threadIDsReadyToRetry(["thread-1"], now: Date(timeIntervalSince1970: 129)),
            []
        )
        XCTAssertEqual(
            store.threadIDsReadyToRetry(["thread-1"], now: Date(timeIntervalSince1970: 130)),
            ["thread-1"]
        )
    }
}
