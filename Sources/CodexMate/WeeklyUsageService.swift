import Foundation

actor WeeklyUsageService {
    private static let rateLimitsMethod = "account/rateLimits/read"

    private let client: CodexAppServerClient
    private let codexBinaryURLProvider: @Sendable () throws -> URL
    private var callbacksConfigured = false

    init(
        client: CodexAppServerClient = CodexAppServerClient(requestTimeout: 30),
        codexBinaryURLProvider: @escaping @Sendable () throws -> URL = CodexBinaryLocator.locate
    ) {
        self.client = client
        self.codexBinaryURLProvider = codexBinaryURLProvider
    }

    func read() async throws -> WeeklyUsageReading {
        await configureCallbacksIfNeeded()

        if await !client.isConnected() {
            let codexBinaryURL = try codexBinaryURLProvider()
            _ = try await client.start(codexBinaryURL: codexBinaryURL)
        }

        let startedAt = Date()
        DebugTraceLogger.log(
            "Weekly usage app-server request started method=\(Self.rateLimitsMethod)"
        )

        do {
            let response: AccountRateLimitsResponse = try await client.call(
                method: Self.rateLimitsMethod
            )
            let reading = try WeeklyUsageParser.reading(from: response)
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            DebugTraceLogger.log(
                "Weekly usage app-server request succeeded method=\(Self.rateLimitsMethod) elapsedMs=\(elapsedMilliseconds)"
            )
            return reading
        } catch {
            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            DebugTraceLogger.log(
                "Weekly usage app-server request failed method=\(Self.rateLimitsMethod) elapsedMs=\(elapsedMilliseconds) errorType=\(String(reflecting: type(of: error))) error=\(error.localizedDescription)"
            )
            throw error
        }
    }

    func stop() async {
        await client.stop()
    }

    private func configureCallbacksIfNeeded() async {
        guard !callbacksConfigured else {
            return
        }

        await client.setCallbacks(
            onMessage: { message in
                guard case let .diagnostic(text) = message else {
                    return
                }
                DebugTraceLogger.log("Weekly usage app-server diagnostic: \(text)")
            },
            onTermination: { reason in
                guard let reason else {
                    return
                }
                DebugTraceLogger.log("Weekly usage app-server terminated: \(reason)")
            }
        )
        callbacksConfigured = true
    }
}
