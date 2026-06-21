import AppKit
@preconcurrency import ApplicationServices

enum AccessibilityPermission {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            preconditionFailure("Invalid Accessibility settings URL.")
        }

        guard NSWorkspace.shared.open(url) else {
            preconditionFailure("Failed to open Accessibility settings.")
        }
    }
}
