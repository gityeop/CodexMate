import Foundation

actor WeeklyUsageService {
    private let client: CodexAppServerClient
    private let codexBinaryURLProvider: @Sendable () throws -> URL

    init(
        client: CodexAppServerClient = CodexAppServerClient(requestTimeout: 10),
        codexBinaryURLProvider: @escaping @Sendable () throws -> URL = CodexBinaryLocator.locate
    ) {
        self.client = client
        self.codexBinaryURLProvider = codexBinaryURLProvider
    }

    func read() async throws -> WeeklyUsageReading {
        if await !client.isConnected() {
            let codexBinaryURL = try codexBinaryURLProvider()
            _ = try await client.start(codexBinaryURL: codexBinaryURL)
        }

        let response: AccountRateLimitsResponse = try await client.call(
            method: "account/rateLimits/read"
        )
        return try WeeklyUsageParser.reading(from: response)
    }

    func stop() async {
        await client.stop()
    }
}
