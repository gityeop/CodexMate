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

struct ClaudeUsageHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

actor ClaudeUsageService {
    typealias CredentialsLoader = @Sendable () throws -> ClaudeOAuthCredentials
    typealias Fetcher = @Sendable (URLRequest) async throws -> ClaudeUsageHTTPResponse

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeaderValue = "oauth-2025-04-20"

    static let urlSessionFetch: Fetcher = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ClaudeUsageHTTPResponse(statusCode: statusCode, body: data)
    }

    private let loadCredentials: CredentialsLoader
    private let fetch: Fetcher
    private let now: @Sendable () -> Date

    init(
        loadCredentials: @escaping CredentialsLoader = { try ClaudeDesktopCredentialsStore.loadCredentials() },
        fetch: @escaping Fetcher = ClaudeUsageService.urlSessionFetch,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loadCredentials = loadCredentials
        self.fetch = fetch
        self.now = now
    }

    func read() async throws -> ClaudeUsageReading {
        let credentials = try currentCredentials()

        do {
            return try await requestUsage(with: credentials)
        } catch ClaudeUsageError.unauthorized {
            // Desktop may have rotated the token while the request was in flight.
            let reloadedCredentials = try currentCredentials()
            guard reloadedCredentials.accessToken != credentials.accessToken else {
                throw ClaudeUsageError.unauthorized
            }

            return try await requestUsage(with: reloadedCredentials)
        }
    }

    private func currentCredentials() throws -> ClaudeOAuthCredentials {
        let credentials = try loadCredentials()
        guard !credentials.isExpired(at: now()) else {
            throw ClaudeUsageError.tokenExpired
        }
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
