import XCTest
@testable import CodexMate

@MainActor
final class FallbackRecentThreadListingTests: XCTestCase {
    func testRecentThreadsMergesFallbackResultsWhenBothSourcesSucceed() async throws {
        let listing = FallbackRecentThreadListing(
            primary: FakeListing(result: .success([
                thread(id: "alpha", updatedAt: 300, cwd: "/tmp/alpha-project")
            ])),
            fallback: FakeListing(result: .success([
                thread(id: "codexmate", updatedAt: 250, cwd: "/Users/imsang-yeob/codextension"),
                thread(id: "popclip", updatedAt: 200, cwd: "/Users/imsang-yeob/.gemini/antigravity/scratch/PopClipClone/Sources/OnText")
            ]))
        )

        let threads = try await listing.recentThreads(limit: 10)

        XCTAssertEqual(threads.map(\.id), ["alpha", "codexmate", "popclip"])
        XCTAssertEqual(
            threads.map(\.cwd),
            [
                "/tmp/alpha-project",
                "/Users/imsang-yeob/codextension",
                "/Users/imsang-yeob/.gemini/antigravity/scratch/PopClipClone/Sources/OnText",
            ]
        )
    }

    func testRecentThreadsUsesFallbackWhenPrimaryReturnsNoThreads() async throws {
        let listing = FallbackRecentThreadListing(
            primary: FakeListing(result: .success([])),
            fallback: FakeListing(result: .success([
                thread(id: "codexmate", updatedAt: 250, cwd: "/Users/imsang-yeob/codextension")
            ]))
        )

        let threads = try await listing.recentThreads(limit: 10)

        XCTAssertEqual(threads.map(\.id), ["codexmate"])
    }

    func testRecentThreadsPreservesPrimaryStatusWhileHydratingMetadataFromFallback() async throws {
        let listing = FallbackRecentThreadListing(
            primary: FakeListing(result: .success([
                thread(
                    id: "alpha",
                    updatedAt: 300,
                    cwd: "/tmp/alpha-project",
                    status: .active(flags: [.waitingOnUserInput])
                )
            ])),
            fallback: FakeListing(result: .success([
                thread(
                    id: "alpha",
                    updatedAt: 300,
                    cwd: "/tmp/alpha-project",
                    status: .notLoaded,
                    path: "/tmp/alpha-thread.jsonl",
                    source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}"#
                )
            ]))
        )

        let threads = try await listing.recentThreads(limit: 10)

        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.status, .active(flags: [.waitingOnUserInput]))
        XCTAssertEqual(threads.first?.path, "/tmp/alpha-thread.jsonl")
        XCTAssertEqual(threads.first?.source, #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}"#)
    }

    func testRecentThreadsIncludesFallbackOnlyThreadWhenItIsNewerThanPrimaryWindow() async throws {
        let listing = FallbackRecentThreadListing(
            primary: FakeListing(result: .success([
                thread(id: "alpha", updatedAt: 300, cwd: "/tmp/alpha-project"),
                thread(id: "beta", updatedAt: 200, cwd: "/tmp/beta-project")
            ])),
            fallback: FakeListing(result: .success([
                thread(id: "gamma", updatedAt: 400, cwd: "/tmp/gamma-project")
            ]))
        )

        let threads = try await listing.recentThreads(limit: 2)

        XCTAssertEqual(threads.map(\.id), ["gamma", "alpha"])
    }

    func testRecentThreadsStartsPrimaryAndFallbackFetchesInParallel() async throws {
        let gate = AsyncGate()
        let primaryStarted = expectation(description: "primary started")
        let fallbackStarted = expectation(description: "fallback started")
        let listing = FallbackRecentThreadListing(
            primary: BlockingListing(
                result: .success([thread(id: "alpha", updatedAt: 300, cwd: "/tmp/alpha-project")]),
                startedExpectation: primaryStarted,
                gate: gate
            ),
            fallback: BlockingListing(
                result: .success([thread(id: "beta", updatedAt: 200, cwd: "/tmp/beta-project")]),
                startedExpectation: fallbackStarted,
                gate: gate
            )
        )

        let task = Task {
            try await listing.recentThreads(limit: 10)
        }

        await fulfillment(of: [primaryStarted, fallbackStarted], timeout: 1.0)
        await gate.open()

        let threads = try await task.value

        XCTAssertEqual(threads.map(\.id), ["alpha", "beta"])
    }
}

private actor FakeListing: RecentThreadListing {
    let result: Result<[CodexThread], Error>

    init(result: Result<[CodexThread], Error>) {
        self.result = result
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        try result.get()
    }
}

private actor BlockingListing: RecentThreadListing {
    let result: Result<[CodexThread], Error>
    let startedExpectation: XCTestExpectation
    let gate: AsyncGate

    init(
        result: Result<[CodexThread], Error>,
        startedExpectation: XCTestExpectation,
        gate: AsyncGate
    ) {
        self.result = result
        self.startedExpectation = startedExpectation
        self.gate = gate
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        startedExpectation.fulfill()
        await gate.wait()
        return try result.get()
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }

        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { continuation in
            continuation.resume()
        }
    }
}

private func thread(id: String, updatedAt: Int, cwd: String) -> CodexThread {
    thread(id: id, updatedAt: updatedAt, cwd: cwd, status: .idle)
}

private func thread(
    id: String,
    updatedAt: Int,
    cwd: String,
    status: CodexThreadStatus,
    path: String? = nil,
    source: String? = nil
) -> CodexThread {
    CodexThread(
        id: id,
        preview: id,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        status: status,
        cwd: cwd,
        name: id,
        path: path,
        source: source
    )
}
