import XCTest
@testable import CodexMate

final class CodexDesktopRemoteStateReaderTests: XCTestCase {
    func testRemoteConfigurationReaderLoadsConnectionsForRemoteProjects() throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectoryURL = tempDirectoryURL.appending(path: "codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }

        try writeGlobalState(
            to: codexDirectoryURL,
            contents: """
            {
              "remote-projects": [
                {
                  "id": "remote-project-1",
                  "hostId": "remote-ssh-codex-managed:oracle-openclaw",
                  "remotePath": "/home/ubuntu",
                  "label": "ubuntu"
                }
              ],
              "codex-managed-remote-connections": [
                {
                  "hostId": "unused-host",
                  "hostname": "unused@example.com"
                },
                {
                  "hostId": "remote-ssh-codex-managed:oracle-openclaw",
                  "hostname": "ubuntu@168.107.60.232",
                  "sshPort": 2200,
                  "identity": "~/.ssh/oci_a1"
                }
              ]
            }
            """
        )

        let reader = RemoteCodexStateConfigurationReader(
            codexDirectoryURLProvider: { codexDirectoryURL }
        )

        XCTAssertEqual(
            try reader.loadConnections(),
            [
                CodexRemoteConnection(
                    hostID: "remote-ssh-codex-managed:oracle-openclaw",
                    hostname: "ubuntu@168.107.60.232",
                    sshPort: 2200,
                    identity: "~/.ssh/oci_a1"
                )
            ]
        )
    }

    func testRemoteThreadReaderHydratesThreadMetadataFromConfiguredHost() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectoryURL = tempDirectoryURL.appending(path: "codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }
        try writeRemoteGlobalState(to: codexDirectoryURL)

        let runner = FakeRemoteCodexStateQueryRunner(
            responses: [
                """
                {
                  "threads": [
                    {
                      "id": "019e6b5b-7d2b-7421-bf17-0939e3d75cf5",
                      "preview": "hermes 업데이트 해줘",
                      "createdAt": 1779917623,
                      "updatedAt": 1779917838,
                      "status": { "type": "idle" },
                      "cwd": "/home/ubuntu",
                      "name": "Hermes 업데이트",
                      "path": "/home/ubuntu/.codex/sessions/rollout.jsonl",
                      "source": null,
                      "agentRole": null,
                      "agentNickname": null
                    }
                  ]
                }
                """
            ]
        )
        let reader = RemoteDesktopStateThreadReader(
            codexDirectoryURLProvider: { codexDirectoryURL },
            runner: runner
        )

        let threads = try await reader.threads(threadIDs: ["019e6b5b-7d2b-7421-bf17-0939e3d75cf5"])

        XCTAssertEqual(threads.map(\.id), ["019e6b5b-7d2b-7421-bf17-0939e3d75cf5"])
        XCTAssertEqual(threads.first?.name, "Hermes 업데이트")
        XCTAssertEqual(threads.first?.cwd, "/home/ubuntu")
        XCTAssertEqual(threads.first?.status, .idle)
        let recordedQueries = await runner.recordedQueries()
        XCTAssertEqual(
            recordedQueries,
            [
                RecordedRemoteQuery(
                    query: .threads(["019e6b5b-7d2b-7421-bf17-0939e3d75cf5"]),
                    connection: CodexRemoteConnection(
                        hostID: "remote-ssh-codex-managed:oracle-openclaw",
                        hostname: "ubuntu@168.107.60.232",
                        sshPort: nil,
                        identity: "~/.ssh/oci_a1"
                    )
                )
            ]
        )
    }

    func testRemoteRecentThreadsSortsAndLimitsRemoteRows() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectoryURL = tempDirectoryURL.appending(path: "codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }
        try writeRemoteGlobalState(to: codexDirectoryURL)

        let runner = FakeRemoteCodexStateQueryRunner(
            responses: [
                """
                {
                  "threads": [
                    {
                      "id": "remote-old",
                      "preview": "old",
                      "createdAt": 100,
                      "updatedAt": 100,
                      "status": { "type": "idle" },
                      "cwd": "/home/ubuntu",
                      "name": "Old",
                      "path": null,
                      "source": null,
                      "agentRole": null,
                      "agentNickname": null
                    },
                    {
                      "id": "remote-new",
                      "preview": "new",
                      "createdAt": 100,
                      "updatedAt": 200,
                      "status": { "type": "idle" },
                      "cwd": "/home/ubuntu",
                      "name": "New",
                      "path": null,
                      "source": null,
                      "agentRole": null,
                      "agentNickname": null
                    }
                  ]
                }
                """
            ]
        )
        let reader = RemoteDesktopStateThreadReader(
            codexDirectoryURLProvider: { codexDirectoryURL },
            runner: runner
        )

        let threads = try await reader.recentThreads(limit: 1)

        XCTAssertEqual(threads.map(\.id), ["remote-new"])
        let recordedQueries = await runner.recordedQueries()
        XCTAssertEqual(recordedQueries.map(\.query), [.recent(limit: 1)])
    }

    func testRemoteThreadReaderReturnsPresentAndArchivedIDs() async throws {
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let codexDirectoryURL = tempDirectoryURL.appending(path: "codex-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectoryURL) }
        try writeRemoteGlobalState(to: codexDirectoryURL)

        let runner = FakeRemoteCodexStateQueryRunner(
            responses: [
                #"{"threadIDs":["remote-present"]}"#,
                #"{"threadIDs":["remote-archived"]}"#,
            ]
        )
        let reader = RemoteDesktopStateThreadReader(
            codexDirectoryURLProvider: { codexDirectoryURL },
            runner: runner
        )

        let present = try await reader.presentThreadIDs(threadIDs: ["remote-present", "missing"])
        let archived = try await reader.archivedThreadIDs(threadIDs: ["remote-archived", "missing"])

        XCTAssertEqual(present, ["remote-present"])
        XCTAssertEqual(archived, ["remote-archived"])
        let recordedQueries = await runner.recordedQueries()
        XCTAssertEqual(
            recordedQueries.map(\.query),
            [
                .present(["missing", "remote-present"]),
                .archived(["missing", "remote-archived"]),
            ]
        )
    }

    private func writeRemoteGlobalState(to codexDirectoryURL: URL) throws {
        try writeGlobalState(
            to: codexDirectoryURL,
            contents: """
            {
              "remote-projects": [
                {
                  "id": "remote-project-1",
                  "hostId": "remote-ssh-codex-managed:oracle-openclaw",
                  "remotePath": "/home/ubuntu",
                  "label": "ubuntu"
                }
              ],
              "codex-managed-remote-connections": [
                {
                  "hostId": "remote-ssh-codex-managed:oracle-openclaw",
                  "hostname": "ubuntu@168.107.60.232",
                  "sshPort": null,
                  "identity": "~/.ssh/oci_a1"
                }
              ]
            }
            """
        )
    }

    private func writeGlobalState(to codexDirectoryURL: URL, contents: String) throws {
        let data = try XCTUnwrap(contents.data(using: .utf8))
        try data.write(
            to: codexDirectoryURL.appendingPathComponent(".codex-global-state.json", isDirectory: false)
        )
    }
}

private struct RecordedRemoteQuery: Equatable, Sendable {
    let query: RemoteCodexStateQuery
    let connection: CodexRemoteConnection
}

private actor FakeRemoteCodexStateQueryRunner: RemoteCodexStateQueryRunning {
    private var responses: [Data]
    private var queries: [RecordedRemoteQuery] = []

    init(responses: [String]) {
        self.responses = responses.map { Data($0.utf8) }
    }

    func run(query: RemoteCodexStateQuery, connection: CodexRemoteConnection) async throws -> Data {
        queries.append(RecordedRemoteQuery(query: query, connection: connection))
        guard !responses.isEmpty else {
            return Data(#"{"threads":[]}"#.utf8)
        }

        return responses.removeFirst()
    }

    func recordedQueries() -> [RecordedRemoteQuery] {
        queries
    }
}
