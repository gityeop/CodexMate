import XCTest

enum HeadlessAppKitTestSupport {
    static func skipIfNeeded() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true" {
            throw XCTSkip("Requires a WindowServer-backed AppKit session.")
        }
    }
}
