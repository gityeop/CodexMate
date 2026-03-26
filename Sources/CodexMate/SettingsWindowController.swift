import AppKit
import Combine
import SwiftUI
import KeyboardShortcuts

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: SettingsViewModel
    private var cancellables: Set<AnyCancellable> = []
    var onVisibilityChanged: ((Bool) -> Void)?
    var isWindowVisible: Bool { window?.isVisible == true }

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel

        let contentView = SettingsView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titleVisibility = .visible
        window.setContentSize(NSSize(width: 520, height: 500))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        updateWindowTitle()

        viewModel.objectWillChange
            .sink { [weak self] _ in
                self?.updateWindowTitle()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        updateWindowTitle()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        notifyVisibilityChanged(true)
    }

    func windowWillClose(_ notification: Notification) {
        notifyVisibilityChanged(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        notifyVisibilityChanged(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        notifyVisibilityChanged(true)
    }

    private func updateWindowTitle() {
        window?.title = viewModel.text("settings.windowTitle")
    }

    private func notifyVisibilityChanged(_ isVisible: Bool) {
        onVisibilityChanged?(isVisible)
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section(viewModel.text("settings.generalSection")) {
                Picker(viewModel.text("settings.languageLabel"), selection: languageBinding) {
                    ForEach(viewModel.languageOptions) { language in
                        Text(viewModel.label(for: language)).tag(language)
                    }
                }

                Picker(viewModel.text("settings.displayModeLabel"), selection: displayModeBinding) {
                    ForEach(viewModel.displayModeOptions) { displayMode in
                        Text(viewModel.label(for: displayMode)).tag(displayMode)
                    }
                }

                if let message = viewModel.displayModeMessage {
                    helpText(message)
                }

                Stepper(
                    value: threadsPerProjectBinding,
                    in: viewModel.threadsPerProjectLimitRange
                ) {
                    Text(viewModel.threadsPerProjectLimitLabel)
                }
                helpText(viewModel.text("settings.threadsPerProjectHelp"))

                Toggle(
                    viewModel.text("settings.launchAtLogin"),
                    isOn: launchAtLoginBinding
                )
                .disabled(!viewModel.launchAtLoginSnapshot.isAvailable)

                if let message = viewModel.launchAtLoginMessage {
                    helpText(message)
                }
            }

            Section(viewModel.text("settings.shortcutSection")) {
                VStack(alignment: .leading, spacing: 8) {
                    KeyboardShortcuts.Recorder(
                        viewModel.text("settings.shortcutLabel"),
                        name: viewModel.shortcutName
                    )
                    helpText(viewModel.text("settings.shortcutHelp"))
                }
            }

            Section(viewModel.text("settings.updatesSection")) {
                Toggle(
                    viewModel.text("settings.updates.autoCheck"),
                    isOn: automaticUpdatesBinding
                )
                .disabled(!viewModel.updaterSnapshot.isAvailable)

                Button(viewModel.text("settings.updates.checkNow")) {
                    viewModel.checkForUpdates()
                }
                .disabled(!viewModel.updaterSnapshot.canCheckForUpdates)

                if let message = viewModel.updatesMessage {
                    helpText(message)
                }
            }

            Section(viewModel.text("settings.notificationsSection")) {
                Toggle(
                    viewModel.text("settings.notifications.attention"),
                    isOn: attentionNotificationsBinding
                )
                Toggle(
                    viewModel.text("settings.notifications.completed"),
                    isOn: completionNotificationsBinding
                )
                Toggle(
                    viewModel.text("settings.notifications.failed"),
                    isOn: failureNotificationsBinding
                )
                helpText(viewModel.text("settings.notifications.help"))
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 520, minHeight: 500)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { viewModel.preferences.language },
            set: { viewModel.setLanguage($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchAtLoginSnapshot.isEnabled },
            set: { viewModel.setLaunchAtLoginEnabled($0) }
        )
    }

    private var displayModeBinding: Binding<AppDisplayMode> {
        Binding(
            get: { viewModel.preferences.displayMode },
            set: { viewModel.setDisplayMode($0) }
        )
    }

    private var threadsPerProjectBinding: Binding<Int> {
        Binding(
            get: { viewModel.preferences.threadsPerProjectLimit },
            set: { viewModel.setThreadsPerProjectLimit($0) }
        )
    }

    private var automaticUpdatesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.updaterSnapshot.automaticallyChecksForUpdates },
            set: { viewModel.setAutomaticallyChecksForUpdates($0) }
        )
    }

    private var attentionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.attentionNotificationsEnabled },
            set: { viewModel.preferences.attentionNotificationsEnabled = $0 }
        )
    }

    private var completionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.completionNotificationsEnabled },
            set: { viewModel.preferences.completionNotificationsEnabled = $0 }
        )
    }

    private var failureNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.preferences.failureNotificationsEnabled },
            set: { viewModel.preferences.failureNotificationsEnabled = $0 }
        )
    }

    @ViewBuilder
    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
