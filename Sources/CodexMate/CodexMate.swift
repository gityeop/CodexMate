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

        static func promoMockupEnabled(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Bool {
            if arguments.contains("--promo-mockup")
                || arguments.contains("--promo-mockup-menubar")
                || arguments.contains("--promo-mockup-notch") {
                return true
            }
            return truthyValue(for: "CODEXMATE_PROMO_MOCKUP", environment: environment)
        }

        static func promoMockupDisplayMode(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> AppDisplayMode? {
            if arguments.contains("--promo-mockup-notch") {
                return .notch
            }

            if arguments.contains("--promo-mockup-menubar") {
                return .menuBar
            }

            guard let rawValue = environment["CODEXMATE_PROMO_MOCKUP_DISPLAY_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else {
                return nil
            }

            switch rawValue.lowercased() {
            case "menubar", "menu-bar":
                return .menuBar
            case "notch":
                return .notch
            default:
                preconditionFailure("Invalid promo mockup display mode: \(rawValue)")
            }
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
        let promoMockupDisplayMode = LaunchEnvironment.promoMockupDisplayMode()
        let promoMockupEnabled = promoMockupDisplayMode != nil || LaunchEnvironment.promoMockupEnabled()
        DebugTraceLogger.log(
            "main start regularAppMode=\(regularAppMode) openSettingsOnLaunch=\(openSettingsOnLaunch) promoMockup=\(promoMockupEnabled) promoMockupDisplayMode=\((promoMockupDisplayMode ?? .menuBar).rawValue) os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )

        let appDelegate = AppDelegate(
            openSettingsOnLaunch: openSettingsOnLaunch,
            promoMockupEnabled: promoMockupEnabled,
            promoMockupDisplayMode: promoMockupDisplayMode ?? .menuBar
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
