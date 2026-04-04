import XCTest
@testable import CodexMate

@MainActor
final class FallbackRecentThreadListingTests: XCTestCase {
    func testRecentThreadsMergesPrimaryAndFallbackResults() async throws {
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
        XCTAssertEqual(threads.map(\.cwd), [
            "/tmp/alpha-project",
            "/Users/imsang-yeob/codextension",
            "/Users/imsang-yeob/.gemini/antigravity/scratch/PopClipClone/Sources/OnText"
        ])
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

private func thread(id: String, updatedAt: Int, cwd: String) -> CodexThread {
    CodexThread(
        id: id,
        preview: id,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        status: .idle,
        cwd: cwd,
        name: id
    )
}
