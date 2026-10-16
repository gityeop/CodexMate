import Foundation

enum ClaudeCodePaths {
    static func configDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let customPath = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customPath.isEmpty {
            let expandedPath = (customPath as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .standardizedFileURL
    }

    static func projectsDirectoryURL() -> URL {
        configDirectoryURL().appendingPathComponent("projects", isDirectory: true)
    }
}

/// Reads the sign-in that Claude Code already stored on this Mac. CodexMate never refreshes or
/// rewrites it, so Claude Code stays the single owner of the token.
enum ClaudeCredentialsStore {
    static let keychainServiceName = "Claude Code-credentials"

    static func loadCredentialsData() -> Data? {
        if let keychainData = keychainCredentialsData() {
            return keychainData
        }

        let fileURL = ClaudeCodePaths.configDirectoryURL()
            .appendingPathComponent(".credentials.json", isDirectory: false)
        return try? Data(contentsOf: fileURL)
    }

    /// Uses the system `security` tool so a one-time "Always Allow" survives CodexMate rebuilds.
    private static func keychainCredentialsData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainServiceName, "-w"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            DebugTraceLogger.log("Claude credentials keychain lookup failed to start: \(error.localizedDescription)")
            return nil
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        guard let text = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return nil
        }

        return Data(text.utf8)
    }
}

struct ClaudeUsageHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

actor ClaudeUsageService {
    typealias CredentialsDataLoader = @Sendable () -> Data?
    typealias Fetcher = @Sendable (URLRequest) async throws -> ClaudeUsageHTTPResponse

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeaderValue = "oauth-2025-04-20"

    static let urlSessionFetch: Fetcher = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ClaudeUsageHTTPResponse(statusCode: statusCode, body: data)
    }

    private let loadCredentialsData: CredentialsDataLoader
    private let fetch: Fetcher
    private let now: @Sendable () -> Date
    private var cachedCredentials: ClaudeOAuthCredentials?

    init(
        loadCredentialsData: @escaping CredentialsDataLoader = { ClaudeCredentialsStore.loadCredentialsData() },
        fetch: @escaping Fetcher = ClaudeUsageService.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadCredentialsData = loadCredentialsData
        self.fetch = fetch
        self.now = now
    }

    func read() async throws -> ClaudeUsageReading {
        let credentials = try currentCredentials(forceReload: false)

        do {
            return try await requestUsage(with: credentials)
        } catch ClaudeUsageError.unauthorized {
            // Claude Code may have rotated the token since it was cached.
            let reloadedCredentials = try currentCredentials(forceReload: true)
            guard reloadedCredentials.accessToken != credentials.accessToken else {
                throw ClaudeUsageError.unauthorized
            }

            return try await requestUsage(with: reloadedCredentials)
        }
    }

    private func currentCredentials(forceReload: Bool) throws -> ClaudeOAuthCredentials {
        let date = now()
        if !forceReload,
           let cachedCredentials,
           !cachedCredentials.isExpired(at: date) {
            return cachedCredentials
        }

        cachedCredentials = nil
        guard let data = loadCredentialsData() else {
            throw ClaudeUsageError.credentialsNotFound
        }

        let credentials = try ClaudeCredentialsParser.credentials(from: data)
        guard !credentials.isExpired(at: date) else {
            throw ClaudeUsageError.tokenExpired
        }

        cachedCredentials = credentials
        return credentials
    }

    private func requestUsage(with credentials: ClaudeOAuthCredentials) async throws -> ClaudeUsageReading {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMate", forHTTPHeaderField: "User-Agent")

        let response = try await fetch(request)
        switch response.statusCode {
        case 200..<300:
            return try ClaudeUsageParser.reading(from: response.body, readAt: now())
        case 401, 403:
            throw ClaudeUsageError.unauthorized
        default:
            throw ClaudeUsageError.httpStatus(response.statusCode)
        }
    }
}
