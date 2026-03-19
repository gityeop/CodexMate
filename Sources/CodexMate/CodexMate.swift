import AppKit

@main
struct CodexMate {
    @MainActor
    static func main() {
        let appDelegate = AppDelegate()
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
