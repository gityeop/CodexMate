import Foundation

struct CodexRemoteConnection: Equatable, Sendable {
    let hostID: String
    let hostname: String
    let sshPort: Int?
    let identity: String?
}

enum RemoteCodexStateQuery: Equatable, Sendable {
    case threads(Set<String>)
    case recent(limit: Int)
    case present(Set<String>)
    case archived(Set<String>)

    fileprivate var payload: Payload {
        switch self {
        case let .threads(threadIDs):
            Payload(mode: "threads", threadIDs: threadIDs.sorted(), limit: nil)
        case let .recent(limit):
            Payload(mode: "recent", threadIDs: nil, limit: max(0, limit))
        case let .present(threadIDs):
            Payload(mode: "present", threadIDs: threadIDs.sorted(), limit: nil)
        case let .archived(threadIDs):
            Payload(mode: "archived", threadIDs: threadIDs.sorted(), limit: nil)
        }
    }

    fileprivate struct Payload: Encodable, Sendable {
        let mode: String
        let threadIDs: [String]?
        let limit: Int?
    }
}

protocol RemoteCodexStateQueryRunning: Sendable {
    func run(query: RemoteCodexStateQuery, connection: CodexRemoteConnection) async throws -> Data
}

actor RemoteDesktopStateThreadReader: ThreadMetadataReading, RecentThreadListing {
    private let configurationReader: RemoteCodexStateConfigurationReader
    private let runner: any RemoteCodexStateQueryRunning

    init(
        codexDirectoryURLProvider: @escaping @Sendable () -> URL,
        runner: any RemoteCodexStateQueryRunning = SSHRemoteCodexStateQueryRunner()
    ) {
        configurationReader = RemoteCodexStateConfigurationReader(
            codexDirectoryURLProvider: codexDirectoryURLProvider
        )
        self.runner = runner
    }

    func threads(threadIDs: Set<String>) async throws -> [CodexThread] {
        guard !threadIDs.isEmpty else {
            return []
        }

        return try await remoteThreads(query: .threads(threadIDs), limit: threadIDs.count)
    }

    func recentThreads(limit: Int) async throws -> [CodexThread] {
        guard limit > 0 else {
            return []
        }

        return try await remoteThreads(query: .recent(limit: limit), limit: limit)
    }

    func presentThreadIDs(threadIDs: Set<String>) async throws -> Set<String> {
        guard !threadIDs.isEmpty else {
            return []
        }

        let responses = try await remoteResponses(query: .present(threadIDs))
        return Set(responses.flatMap { $0.threadIDs ?? [] })
    }

    func archivedThreadIDs(threadIDs: Set<String>) async throws -> Set<String> {
        guard !threadIDs.isEmpty else {
            return []
        }

        let responses = try await remoteResponses(query: .archived(threadIDs))
        return Set(responses.flatMap { $0.threadIDs ?? [] })
    }

    private func remoteThreads(query: RemoteCodexStateQuery, limit: Int) async throws -> [CodexThread] {
        let responses = try await remoteResponses(query: query)
        var threadsByID: [String: CodexThread] = [:]

        for thread in responses.flatMap({ $0.threads ?? [] }) {
            if let existing = threadsByID[thread.id], existing.updatedAt >= thread.updatedAt {
                continue
            }
            threadsByID[thread.id] = thread
        }

        return Array(
            threadsByID.values.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }

                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
        )
    }

    private func remoteResponses(query: RemoteCodexStateQuery) async throws -> [RemoteCodexStateQueryResponse] {
        let connections = try configurationReader.loadConnections()
        guard !connections.isEmpty else {
            return []
        }

        let runner = runner
        return try await withThrowingTaskGroup(of: RemoteCodexStateQueryResponse.self) { group in
            for connection in connections {
                group.addTask {
                    let data = try await runner.run(query: query, connection: connection)
                    return try JSONDecoder().decode(RemoteCodexStateQueryResponse.self, from: data)
                }
            }

            var responses: [RemoteCodexStateQueryResponse] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }
    }
}

private struct RemoteCodexStateQueryResponse: Decodable {
    let threads: [CodexThread]?
    let threadIDs: [String]?
}

struct RemoteCodexStateConfigurationReader {
    private let fileManager: FileManager
    private let codexDirectoryURLProvider: @Sendable () -> URL

    init(
        fileManager: FileManager = .default,
        codexDirectoryURLProvider: @escaping @Sendable () -> URL
    ) {
        self.fileManager = fileManager
        self.codexDirectoryURLProvider = codexDirectoryURLProvider
    }

    func loadConnections() throws -> [CodexRemoteConnection] {
        let fileURL = codexDirectoryURLProvider()
            .standardizedFileURL
            .appendingPathComponent(".codex-global-state.json", isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let state = try JSONDecoder().decode(RemoteCodexGlobalStateFile.self, from: data)
        let remoteHostIDs = Set((state.remoteProjects ?? []).map(\.hostID).filter { !$0.isEmpty })
        guard !remoteHostIDs.isEmpty else {
            return []
        }

        var connectionsByHostID: [String: CodexRemoteConnection] = [:]
        for connection in state.remoteConnections ?? [] {
            let hostID = connection.hostID.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostname = connection.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            guard remoteHostIDs.contains(hostID), !hostname.isEmpty else {
                continue
            }

            connectionsByHostID[hostID] = CodexRemoteConnection(
                hostID: hostID,
                hostname: hostname,
                sshPort: connection.sshPort,
                identity: connection.identity
            )
        }

        return connectionsByHostID.values.sorted { lhs, rhs in
            lhs.hostID.localizedCaseInsensitiveCompare(rhs.hostID) == .orderedAscending
        }
    }
}

private struct RemoteCodexGlobalStateFile: Decodable {
    let remoteProjects: [RemoteProjectRecord]?
    let remoteConnections: [RemoteConnectionRecord]?

    enum CodingKeys: String, CodingKey {
        case remoteProjects = "remote-projects"
        case remoteConnections = "codex-managed-remote-connections"
    }
}

private struct RemoteProjectRecord: Decodable {
    let hostID: String

    enum CodingKeys: String, CodingKey {
        case hostID = "hostId"
    }
}

private struct RemoteConnectionRecord: Decodable {
    let hostID: String
    let hostname: String
    let sshPort: Int?
    let identity: String?

    enum CodingKeys: String, CodingKey {
        case hostID = "hostId"
        case hostname
        case sshPort
        case identity
    }
}

struct SSHRemoteCodexStateQueryRunner: RemoteCodexStateQueryRunning {
    private enum Defaults {
        static let timeout: TimeInterval = 2.5
    }

    func run(query: RemoteCodexStateQuery, connection: CodexRemoteConnection) async throws -> Data {
        let payloadData = try JSONEncoder().encode(query.payload)
        let script = Self.pythonScript(requestData: payloadData)
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = sshArguments(for: connection)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw RemoteCodexStateQueryRunnerError.launchFailed(error.localizedDescription)
        }

        if let scriptData = script.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(scriptData)
        }
        try stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(Defaults.timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                throw RemoteCodexStateQueryRunnerError.timedOut(connection.hostname)
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteCodexStateQueryRunnerError.nonZeroExit(
                Int(process.terminationStatus),
                message ?? "ssh exited with status \(process.terminationStatus)"
            )
        }

        return outputData
    }

    private func sshArguments(for connection: CodexRemoteConnection) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=2",
            "-o", "LogLevel=ERROR",
            "-o", "StrictHostKeyChecking=accept-new",
        ]

        if let identity = connection.identity?.trimmingCharacters(in: .whitespacesAndNewlines),
           !identity.isEmpty {
            arguments.append(contentsOf: ["-i", (identity as NSString).expandingTildeInPath])
        }

        if let sshPort = connection.sshPort {
            arguments.append(contentsOf: ["-p", "\(sshPort)"])
        }

        arguments.append(contentsOf: [connection.hostname, "python3", "-"])
        return arguments
    }

    private static func pythonScript(requestData: Data) -> String {
        let requestBase64 = requestData.base64EncodedString()

        return """
import base64
import glob
import json
import os
import sqlite3

REQUEST = json.loads(base64.b64decode("\(requestBase64)").decode("utf-8"))
MODE = REQUEST.get("mode")
THREAD_IDS = list(dict.fromkeys(REQUEST.get("threadIDs") or []))
THREAD_ID_SET = set(THREAD_IDS)
LIMIT = int(REQUEST.get("limit") or 0)

def compact_string(value):
    if value is None:
        return ""
    return str(value).strip()

def optional_string(value):
    text = compact_string(value)
    return text if text else None

def int_value(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def row_value(row, key, default=None):
    return row[key] if key in row.keys() else default

def meaningful(row):
    if compact_string(row_value(row, "first_user_message")):
        return True
    if compact_string(row_value(row, "title")):
        return True
    if compact_string(row_value(row, "preview")):
        return True
    if int_value(row_value(row, "has_user_event"), 0) != 0:
        return True
    return int_value(row_value(row, "tokens_used"), 0) > 0

def preview_for(row):
    for key in ("first_user_message", "preview", "title"):
        value = compact_string(row_value(row, key))
        if value:
            return value
    return compact_string(row_value(row, "id"))

def iter_session_lines(path):
    if not path or not os.path.exists(path):
        return
    max_tail_bytes = 16 * 1024 * 1024
    with open(path, "rb") as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        start = max(0, size - max_tail_bytes)
        handle.seek(start)
        if start > 0:
            handle.readline()
        for raw_line in handle:
            yield raw_line.decode("utf-8", "replace")

def status_for_session(path):
    if not path or not os.path.exists(path):
        return {"type": "notLoaded"}

    active_turn_ids = set()
    mode_by_turn_id = {}
    unresolved_user_input = set()
    unresolved_approval = set()
    waiting_for_plan_reply = False
    latest_completion_seen = False

    try:
        for line in iter_session_lines(path):
            try:
                event = json.loads(line)
            except Exception:
                continue

            payload = event.get("payload") or {}
            event_type = event.get("type")
            payload_type = payload.get("type")

            if event_type == "event_msg":
                if payload_type == "task_started":
                    turn_id = payload.get("turn_id")
                    if turn_id:
                        active_turn_ids = {turn_id}
                        mode_by_turn_id = {}
                        if payload.get("collaboration_mode_kind"):
                            mode_by_turn_id[turn_id] = payload.get("collaboration_mode_kind")
                    unresolved_user_input.clear()
                    unresolved_approval.clear()
                    waiting_for_plan_reply = False
                elif payload_type == "task_complete":
                    turn_id = payload.get("turn_id")
                    latest_completion_seen = True
                    if turn_id:
                        active_turn_ids.discard(turn_id)
                        waiting_for_plan_reply = mode_by_turn_id.get(turn_id) == "plan"
                        mode_by_turn_id.pop(turn_id, None)
                    unresolved_user_input.clear()
                    unresolved_approval.clear()
                elif payload_type == "turn_aborted":
                    turn_id = payload.get("turn_id")
                    latest_completion_seen = True
                    if turn_id:
                        active_turn_ids.discard(turn_id)
                        mode_by_turn_id.pop(turn_id, None)
                    unresolved_user_input.clear()
                    unresolved_approval.clear()
                    waiting_for_plan_reply = False
                elif payload_type == "exec_approval_request":
                    call_id = payload.get("call_id")
                    if call_id:
                        unresolved_approval.add(call_id)
                elif payload_type in ("exec_command_begin", "exec_command_end"):
                    call_id = payload.get("call_id")
                    if call_id:
                        unresolved_approval.discard(call_id)
            elif event_type == "response_item":
                if payload_type == "message" and payload.get("role") == "user":
                    waiting_for_plan_reply = False
                elif payload_type == "function_call":
                    waiting_for_plan_reply = False
                    call_id = payload.get("call_id")
                    name = payload.get("name")
                    if call_id and name == "request_user_input":
                        unresolved_user_input.add(call_id)
                    elif call_id and name in ("request_approval", "requestApproval"):
                        unresolved_approval.add(call_id)
                elif payload_type == "function_call_output":
                    waiting_for_plan_reply = False
                    call_id = payload.get("call_id")
                    if call_id:
                        unresolved_user_input.discard(call_id)
                        unresolved_approval.discard(call_id)
    except Exception:
        return {"type": "notLoaded"}

    if waiting_for_plan_reply or unresolved_user_input:
        return {"type": "active", "activeFlags": ["waitingOnUserInput"]}
    if unresolved_approval:
        return {"type": "active", "activeFlags": ["waitingOnApproval"]}
    if active_turn_ids:
        return {"type": "active", "activeFlags": []}
    if latest_completion_seen:
        return {"type": "idle"}
    return {"type": "notLoaded"}

def make_thread(row):
    thread_id = compact_string(row_value(row, "id"))
    updated_at = int_value(row_value(row, "updated_at"), 0)
    created_at = int_value(row_value(row, "created_at"), updated_at)
    path = optional_string(row_value(row, "rollout_path"))
    return {
        "id": thread_id,
        "preview": preview_for(row),
        "createdAt": created_at,
        "updatedAt": updated_at,
        "status": status_for_session(path),
        "cwd": compact_string(row_value(row, "cwd")),
        "name": optional_string(row_value(row, "title")),
        "path": path,
        "source": optional_string(row_value(row, "source")),
        "agentRole": optional_string(row_value(row, "agent_role")),
        "agentNickname": optional_string(row_value(row, "agent_nickname")),
    }

def candidate_databases():
    codex_home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    paths = glob.glob(os.path.join(codex_home, "state_*.sqlite"))
    return sorted(paths, key=lambda path: os.path.getmtime(path), reverse=True)

def rows_from_database(database_path):
    connection = sqlite3.connect(database_path)
    connection.row_factory = sqlite3.Row
    try:
        exists = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'threads'"
        ).fetchone()
        if not exists:
            return []

        if MODE == "recent":
            row_limit = max(1, LIMIT * 4 if LIMIT else 256)
            return connection.execute(
                "SELECT * FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT ?",
                (row_limit,),
            ).fetchall()

        if not THREAD_IDS:
            return []

        placeholders = ",".join("?" for _ in THREAD_IDS)
        return connection.execute(
            "SELECT * FROM threads WHERE id IN (" + placeholders + ")",
            THREAD_IDS,
        ).fetchall()
    finally:
        connection.close()

threads_by_id = {}
thread_ids = set()

for database_path in candidate_databases():
    try:
        rows = rows_from_database(database_path)
    except Exception:
        continue

    for row in rows:
        thread_id = compact_string(row_value(row, "id"))
        if not thread_id:
            continue

        archived = int_value(row_value(row, "archived"), 0) != 0
        if MODE == "archived":
            if archived:
                thread_ids.add(thread_id)
            continue

        if archived or not meaningful(row):
            continue

        if MODE == "present":
            thread_ids.add(thread_id)
            continue

        thread = make_thread(row)
        existing = threads_by_id.get(thread_id)
        if existing is None or existing.get("updatedAt", 0) < thread.get("updatedAt", 0):
            threads_by_id[thread_id] = thread

if MODE in ("archived", "present"):
    print(json.dumps({"threadIDs": sorted(thread_ids)}, ensure_ascii=False))
else:
    threads = sorted(
        threads_by_id.values(),
        key=lambda thread: (-int(thread.get("updatedAt", 0)), thread.get("id", "")),
    )
    if MODE == "recent" and LIMIT:
        threads = threads[:LIMIT]
    print(json.dumps({"threads": threads}, ensure_ascii=False))
"""
    }
}

private enum RemoteCodexStateQueryRunnerError: LocalizedError {
    case launchFailed(String)
    case timedOut(String)
    case nonZeroExit(Int, String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "Failed to launch ssh: \(message)"
        case let .timedOut(hostname):
            return "Timed out querying remote Codex state on \(hostname)"
        case let .nonZeroExit(status, message):
            return "Remote Codex state query failed with status \(status): \(message)"
        }
    }
}
