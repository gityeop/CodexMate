import AppKit

@main
struct CodexMate {
    private enum LaunchEnvironment {
        private static let arguments = Set(CommandLine.arguments)

        static func regularAppModeEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            if arguments.contains("--regular-app") {
                return true
            }
            return truthyValue(for: "CODEXMATE_REGULAR_APP", environment: environment)
        }

        static func openSettingsOnLaunchEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            if arguments.contains("--open-settings-on-launch") {
                return true
            }
            return truthyValue(for: "CODEXMATE_OPEN_SETTINGS_ON_LAUNCH", environment: environment)
        }

        private static func truthyValue(
            for key: String,
            environment: [String: String]
        ) -> Bool {
            guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }

            switch rawValue.lowercased() {
            case "1", "true", "yes", "y", "on":
                return true
            default:
                return false
            }
        }
    }

    @MainActor
    static func main() {
        let regularAppMode = LaunchEnvironment.regularAppModeEnabled()
        let openSettingsOnLaunch = LaunchEnvironment.openSettingsOnLaunchEnabled()
        DebugTraceLogger.log(
            "main start regularAppMode=\(regularAppMode) openSettingsOnLaunch=\(openSettingsOnLaunch) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )

        let appDelegate = AppDelegate(
            openSettingsOnLaunch: openSettingsOnLaunch
        )
        DebugTraceLogger.log("main createdAppDelegate")
        let application = NSApplication.shared
        DebugTraceLogger.log("main acquiredNSApplication")
        application.delegate = appDelegate
        application.setActivationPolicy(regularAppMode ? .regular : .accessory)
        DebugTraceLogger.log("main setActivationPolicy mode=\(regularAppMode ? "regular" : "accessory")")
        application.run()
    }
}
