import Foundation

enum ClientMessage: Sendable {
    case notification(method: String, payload: Data)
    case request(id: String, method: String, payload: Data)
    case diagnostic(text: String)
}

enum CodexAppServerClientError: LocalizedError {
    case notConnected
    case invalidResponse
    case invalidResult
    case rpc(code: Int, message: String)
    case decodingFailure(method: String, details: String)
    case processExited(status: Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Codex app-server is not connected."
        case .invalidResponse:
            return "Received an invalid JSON-RPC response."
        case .invalidResult:
            return "Missing result in JSON-RPC response."
        case let .rpc(code, message):
            return "Codex RPC error \(code): \(message)"
        case let .decodingFailure(method, details):
            return "Failed to decode \(method) response: \(details)"
        case let .processExited(status):
            return "Codex app-server exited with status \(status)."
        }
    }
}

actor CodexAppServerClient {
    typealias MessageHandler = @Sendable (ClientMessage) -> Void
    typealias TerminationHandler = @Sendable (String?) -> Void

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<Data, Error>] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var onMessage: MessageHandler?
    private var onTermination: TerminationHandler?

    func setCallbacks(onMessage: MessageHandler?, onTermination: TerminationHandler?) {
        self.onMessage = onMessage
        self.onTermination = onTermination
    }

    func start(codexBinaryURL: URL) async throws {
        guard process == nil else { return }

        let newProcess = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        newProcess.executableURL = codexBinaryURL
        newProcess.arguments = ["app-server", "--listen", "stdio://"]
        newProcess.standardInput = stdinPipe
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = stderrPipe
        newProcess.terminationHandler = { [weak self] process in
            guard let self else { return }

            Task {
                await self.handleTermination(status: process.terminationStatus)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }

            Task {
                await self.handleStandardOutput(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }

            Task {
                await self.handleStandardError(data)
            }
        }

        try newProcess.run()

        process = newProcess
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        let _: InitializeResponse = try await call(
            method: "initialize",
            params: InitializeParams(
                clientInfo: ClientInfo(name: "CodextensionMenubar", version: "0.1.0"),
                capabilities: nil
            )
        )

        try sendNotification(method: "initialized")
    }

    func stop() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdinHandle?.closeFile()
        stdoutHandle?.closeFile()
        stderrHandle?.closeFile()

        process?.standardOutput = nil
        process?.standardError = nil
        process?.terminationHandler = nil
        process?.interrupt()
        process?.terminate()

        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: CodexAppServerClientError.notConnected)
        }

        pendingResponses.removeAll()
    }

    func call<Result: Decodable, Params: Encodable>(method: String, params: Params) async throws -> Result {
        let requestID = nextRequestID
        nextRequestID += 1

        let data = try encoder.encode(JSONRPCRequest(id: requestID, method: method, params: params))

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation

            do {
                try writeLine(data)
            } catch {
                pendingResponses[requestID] = nil
                continuation.resume(throwing: error)
            }
        }

        do {
            return try decodeResult(from: responseData)
        } catch let error as DecodingError {
            throw CodexAppServerClientError.decodingFailure(
                method: method,
                details: describeDecodingError(error)
            )
        }
    }

    private func sendNotification(method: String) throws {
        let data = try encoder.encode(JSONRPCNotification(method: method))
        try writeLine(data)
    }

    private func writeLine(_ data: Data) throws {
        guard let stdinHandle else {
            throw CodexAppServerClientError.notConnected
        }

        var line = data
        line.append(0x0A)
        try stdinHandle.write(contentsOf: line)
    }

    private func decodeResult<Result: Decodable>(from responseData: Data) throws -> Result {
        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw CodexAppServerClientError.invalidResponse
        }

        if let errorObject = object["error"] {
            let errorData = try JSONSerialization.data(withJSONObject: errorObject)
            let payload = try decoder.decode(RPCErrorPayload.self, from: errorData)
            throw CodexAppServerClientError.rpc(code: payload.code, message: payload.message)
        }

        guard let resultObject = object["result"] else {
            throw CodexAppServerClientError.invalidResult
        }

        let resultData = try JSONSerialization.data(withJSONObject: resultObject)
        return try decoder.decode(Result.self, from: resultData)
    }

    private func handleTermination(status: Int32) {
        let terminationHandler = onTermination
        stop()
        terminationHandler?("Codex app-server exited with status \(status)")
    }

    private func handleStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        drainBuffer(&stdoutBuffer, source: .stdout)
    }

    private func handleStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        drainBuffer(&stderrBuffer, source: .stderr)
    }

    private func drainBuffer(_ buffer: inout Data, source: StreamSource) {
        while let range = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)

            if line.isEmpty {
                continue
            }

            switch source {
            case .stdout:
                routeStandardOutputLine(line)
            case .stderr:
                routeStandardErrorLine(line)
            }
        }
    }

    private func routeStandardOutputLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let method = object["method"] as? String {
            if let rawID = object["id"] {
                onMessage?(.request(id: Self.describeRequestID(rawID), method: method, payload: line))
            } else {
                onMessage?(.notification(method: method, payload: line))
            }
            return
        }

        guard let id = Self.integerRequestID(from: object["id"]),
              let continuation = pendingResponses.removeValue(forKey: id)
        else {
            return
        }

        continuation.resume(returning: line)
    }

    private func routeStandardErrorLine(_ line: Data) {
        let text = String(decoding: line, as: UTF8.self)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onMessage?(.diagnostic(text: text))
    }

    private static func integerRequestID(from rawValue: Any?) -> Int? {
        switch rawValue {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func describeRequestID(_ rawValue: Any) -> String {
        switch rawValue {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        case let value as Int:
            return String(value)
        default:
            return "unknown"
        }
    }
}

private enum StreamSource {
    case stdout
    case stderr
}

func describeDecodingError(_ error: DecodingError) -> String {
    switch error {
    case let .keyNotFound(key, context):
        return "missing key '\(key.stringValue)' at \(decodingPath(context.codingPath))"
    case let .valueNotFound(_, context):
        return "missing value at \(decodingPath(context.codingPath))"
    case let .typeMismatch(_, context):
        return "type mismatch at \(decodingPath(context.codingPath))"
    case let .dataCorrupted(context):
        return "invalid data at \(decodingPath(context.codingPath)): \(context.debugDescription)"
    @unknown default:
        return error.localizedDescription
    }
}

private func decodingPath(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else { return "<root>" }

    return codingPath
        .map { key in
            if let index = key.intValue {
                return "[\(index)]"
            }

            return key.stringValue
        }
        .joined(separator: ".")
}

private struct JSONRPCRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

private struct JSONRPCNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
}
