import XCTest
@testable import CodexMate

final class ProjectSearchTests: XCTestCase {
    func testAbbreviationsMatchInOrderAndIgnoreCase() {
        XCTAssertNotNil(ProjectSearch.score(" oTx ", in: "OnText"))
        XCTAssertNotNil(ProjectSearch.score("cdxm", in: "CodexMate"))
        XCTAssertNil(ProjectSearch.score("xto", in: "OnText"))
        XCTAssertNil(ProjectSearch.score("ontextt", in: "OnText"))
    }

    func testExactAndContiguousMatchesRankBeforeScatteredMatches() {
        let names = ["One small Text", "My OnText", "OnText archive", "OnText"]
        let sorted = names.sorted { ProjectSearch.score("ontext", in: $0)! < ProjectSearch.score("ontext", in: $1)! }
        XCTAssertEqual(sorted, ["OnText", "OnText archive", "My OnText", "One small Text"])
    }

    func testKoreanAndAccentedProjectNames() {
        XCTAssertNotNil(ProjectSearch.score("프로검", in: "프로젝트 검색"))
        XCTAssertEqual(ProjectSearch.score("한글", in: "한글".decomposedStringWithCanonicalMapping), 0)
        XCTAssertEqual(ProjectSearch.score("cafe", in: "Café"), 0)
        XCTAssertEqual(ProjectSearch.score("  ", in: "OnText"), 0)
    }

    @MainActor
    func testFilteringAndClearingKeepSelectedProject() throws {
        let suite = "ProjectSearchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectGraphStore(defaults: defaults)
        let catalog = CodexDesktopProjectCatalog(workspaceRoots: [
            .init(path: "/projects/ontext", displayName: "OnText"),
            .init(path: "/projects/codexmate", displayName: "CodexMate")
        ])
        store.update(catalog: catalog, threads: [], language: .english, sourceError: nil)
        store.selectProject("/projects/codexmate")
        store.projectQuery = "otx"
        XCTAssertEqual(store.filteredProjects.map(\.displayName), ["OnText"])
        XCTAssertEqual(store.projectPath, "/projects/codexmate")
        store.projectQuery = "no matching project"
        XCTAssertTrue(store.filteredProjects.isEmpty)
        store.projectQuery = ""
        XCTAssertEqual(store.filteredProjects.map(\.displayName), ["CodexMate", "OnText"])
        XCTAssertEqual(store.projectPath, "/projects/codexmate")
    }
}
