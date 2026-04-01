import AppKit
import Carbon.HIToolbox
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
                    value: projectLimitBinding,
                    in: viewModel.projectLimitRange
                ) {
                    Text(viewModel.projectLimitLabel)
                }
                helpText(viewModel.text("settings.projectLimitHelp"))

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
                    Text(viewModel.text("settings.shortcutLabel"))
                    HStack(spacing: 12) {
                        ShortcutRecorderField(
                            shortcut: viewModel.shortcut,
                            placeholder: viewModel.text("settings.shortcutRecordPlaceholder"),
                            onChange: { viewModel.setShortcut($0) }
                        )
                        .frame(width: 220, height: 28)

                        Button(viewModel.text("settings.shortcutClear")) {
                            viewModel.setShortcut(nil)
                        }
                        .disabled(viewModel.shortcut == nil)
                    }
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

    private var projectLimitBinding: Binding<Int> {
        Binding(
            get: { viewModel.preferences.projectLimit },
            set: { viewModel.setProjectLimit($0) }
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

private struct ShortcutRecorderField: NSViewRepresentable {
    let shortcut: KeyboardShortcuts.Shortcut?
    let placeholder: String
    let onChange: (KeyboardShortcuts.Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderTextField {
        let textField = ShortcutRecorderTextField(frame: .zero)
        textField.onChange = onChange
        return textField
    }

    func updateNSView(_ nsView: ShortcutRecorderTextField, context: Context) {
        nsView.shortcut = shortcut
        nsView.placeholderLabel = placeholder
        nsView.onChange = onChange
    }
}

private final class ShortcutRecorderTextField: NSTextField {
    var shortcut: KeyboardShortcuts.Shortcut? {
        didSet {
            guard !isRecording else { return }
            refreshDisplay()
        }
    }

    var placeholderLabel: String = "" {
        didSet {
            refreshDisplay()
        }
    }

    var onChange: ((KeyboardShortcuts.Shortcut?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    private var isRecording = false {
        didSet {
            refreshDisplay()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        alignment = .center
        font = .systemFont(ofSize: NSFont.systemFontSize)
        lineBreakMode = .byTruncatingTail
        focusRingType = .default
        refreshDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            isRecording = true
        }
        return didBecomeFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let didResignFirstResponder = super.resignFirstResponder()
        if didResignFirstResponder {
            isRecording = false
        }
        return didResignFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = normalizedModifiers(event.modifierFlags)

        if modifiers.isEmpty, event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        if modifiers.isEmpty, let specialKey = event.specialKey, Self.clearKeys.contains(specialKey) {
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }

        let allowsShortcutWithoutModifier = event.specialKey.map { Self.functionKeys.contains($0) } ?? false
        guard !modifiers.subtracting(.shift).isEmpty || allowsShortcutWithoutModifier else {
            NSSound.beep()
            return
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }

        onChange?(shortcut)
        window?.makeFirstResponder(nil)
    }

    private func refreshDisplay() {
        if isRecording {
            stringValue = placeholderLabel
            textColor = .secondaryLabelColor
            return
        }

        if let shortcut {
            stringValue = shortcut.description
            textColor = .labelColor
        } else {
            stringValue = placeholderLabel
            textColor = .secondaryLabelColor
        }
    }

    private func normalizedModifiers(_ modifierFlags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
    }

    private static let clearKeys: Set<NSEvent.SpecialKey> = [.backspace, .delete, .deleteForward]
    private static let functionKeys: Set<NSEvent.SpecialKey> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
        .f21, .f22, .f23, .f24, .f25, .f26, .f27, .f28, .f29, .f30,
        .f31, .f32, .f33, .f34, .f35,
    ]
}
