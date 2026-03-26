import XCTest
@testable import CodexMate

final class DesktopActivityServiceTests: XCTestCase {
    func testRepeatedDatabaseOpenFailuresAreThrottled() async {
        let missingDatabaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "state.sqlite")

        let service = DesktopActivityService(
            stateReader: CodexDesktopStateReader(stateDatabaseURLOverride: missingDatabaseURL)
        )

        let first = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 100)
        )
        let second = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 110)
        )
        let third = await service.load(
            candidateSessionPaths: [:],
            now: Date(timeIntervalSince1970: 131)
        )

        XCTAssertNotNil(first.runtimeErrorMessage)
        XCTAssertNil(second.runtimeErrorMessage)
        XCTAssertNotNil(third.runtimeErrorMessage)
    }
}
