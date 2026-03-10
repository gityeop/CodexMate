import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RefreshInterval {
        static let desktopActivitySeconds: TimeInterval = 1
        static let threadListSeconds: TimeInterval = 5
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let client = CodexAppServerClient()
    private let desktopStateReader = CodexDesktopStateReader()

    private var state = AppStateStore()
    private var desktopActivityTimer: Timer?
    private var threadListTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.title = state.overallStatus.icon

        configureClientCallbacks()
        requestNotificationPermission()
        renderMenu()

        Task {
            await connectAndLoad()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        invalidateTimers()

        Task {
            await client.stop()
        }
    }

    private func configureClientCallbacks() {
        Task { [weak self] in
            guard let self else { return }

            await client.setCallbacks(
                onMessage: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.handleClientMessage(message)
                    }
                },
                onTermination: { [weak self] reason in
                    Task { @MainActor [weak self] in
                        self?.handleClientTermination(reason: reason)
                    }
                }
            )
        }
    }

    private func requestNotificationPermission() {
        guard notificationsEnabled else {
            state.recordDiagnostic("User notifications are disabled outside an .app bundle.")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func connectAndLoad() async {
        state.setConnection(.connecting)
        renderMenu()

        do {
            let binaryURL = try CodexBinaryLocator.locate()
            try await client.start(codexBinaryURL: binaryURL)
            state.setConnection(.connected(binaryPath: binaryURL.path))
            renderMenu()

            try await refreshThreads()
            scheduleRefreshTimers()
        } catch {
            state.setConnection(.failed(message: error.localizedDescription))
            renderMenu()
        }
    }

    private func refreshThreads() async throws {
        let response: ThreadListResponse = try await client.call(
            method: "thread/list",
            params: ThreadListParams(limit: 8, archived: false)
        )

        state.replaceRecentThreads(with: response.data)
        applyDesktopRuntimeOverlay()
        renderMenu()
    }

    private func watchLatestThread() async {
        guard let thread = state.recentThreads.first else { return }

        do {
            let response: ThreadResumeResponse = try await client.call(
                method: "thread/resume",
                params: ThreadResumeParams(threadId: thread.id, persistExtendedHistory: false)
            )

            state.markWatched(thread: response.thread)
            renderMenu()
        } catch {
            state.setConnection(.failed(message: error.localizedDescription))
            renderMenu()
        }
    }

    private func handleClientTermination(reason: String?) {
        invalidateTimers()

        let message = reason ?? "app-server process exited"
        state.setConnection(.failed(message: message))
        renderMenu()
    }

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case let .notification(method, payload):
            handleNotification(method: method, payload: payload)
        case let .request(_, method, payload):
            handleServerRequest(method: method, payload: payload)
        case let .diagnostic(text):
            state.recordDiagnostic(text)
            renderMenu()
        }
    }

    private func handleNotification(method: String, payload: Data) {
        switch method {
        case "thread/started":
            decodeAndApply(payload, as: ThreadStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .threadStarted(notification))
            }
        case "thread/status/changed":
            decodeAndApply(payload, as: ThreadStatusChangedNotification.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .threadStatusChanged(notification))
            }
        case "turn/started":
            decodeAndApply(payload, as: TurnStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .turnStarted(notification))
            }
        case "turn/completed":
            decodeAndApply(payload, as: TurnCompletedNotification.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .turnCompleted(notification))
                sendNotification(
                    title: "Codex turn completed",
                    body: state.notificationBody(forThreadID: notification.threadId, fallback: notification.turn.status.displayName)
                )
            }
        case "error":
            decodeAndApply(payload, as: ErrorNotificationPayload.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .error(notification))

                if !notification.willRetry {
                    sendNotification(
                        title: "Codex error",
                        body: state.notificationBody(forThreadID: notification.threadId, fallback: notification.error.message)
                    )
                }
            }
        default:
            break
        }

        renderMenu()
    }

    private func handleServerRequest(method: String, payload: Data) {
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            decodeAndApply(payload, as: ToolRequestUserInputRequest.self) { [weak self] request in
                guard let self else { return }
                state.apply(serverRequest: .toolUserInput(request))
                state.recordDiagnostic("user-input request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex needs input",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for user input.")
                )
            }
        case "item/commandExecution/requestApproval", "commandExecution/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                state.apply(serverRequest: .approval(request))
                state.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex approval required",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
                )
            }
        case "item/fileChange/requestApproval", "fileChange/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                state.apply(serverRequest: .approval(request))
                state.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex approval required",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
                )
            }
        default:
            break
        }

        renderMenu()
    }

    private func decodeAndApply<T: Decodable>(_ payload: Data, as type: T.Type, apply: (T) -> Void) {
        guard let message = try? JSONDecoder().decode(WireMessage<T>.self, from: payload) else {
            return
        }

        apply(message.params)
    }

    private func sendNotification(title: String, body: String) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private var notificationsEnabled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func scheduleRefreshTimers() {
        invalidateTimers()

        desktopActivityTimer = Timer.scheduledTimer(
            withTimeInterval: RefreshInterval.desktopActivitySeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDesktopActivity()
            }
        }

        threadListTimer = Timer.scheduledTimer(
            withTimeInterval: RefreshInterval.threadListSeconds,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }

                do {
                    try await refreshThreads()
                } catch {
                    state.setConnection(.failed(message: error.localizedDescription))
                    renderMenu()
                }
            }
        }
    }

    private func invalidateTimers() {
        desktopActivityTimer?.invalidate()
        desktopActivityTimer = nil
        threadListTimer?.invalidate()
        threadListTimer = nil
    }

    private func refreshDesktopActivity() {
        applyDesktopRuntimeOverlay()
        renderMenu()
    }

    private func applyDesktopRuntimeOverlay() {
        let candidateThreadIDs = Set(state.recentThreads.map(\.id))

        do {
            let snapshot = try desktopStateReader.snapshot(candidates: candidateThreadIDs)
            state.apply(desktopSnapshot: snapshot)
        } catch {
            state.recordDiagnostic("Desktop activity unavailable: \(error.localizedDescription)")
        }
    }

    private func renderMenu() {
        statusItem.button?.title = state.overallStatus.icon
        menu.removeAllItems()

        menu.addItem(makeStaticItem(title: "Status: \(state.overallStatus.displayName)"))
        menu.addItem(makeStaticItem(title: state.connectionDescription))
        menu.addItem(makeStaticItem(title: state.summaryText))
        menu.addItem(makeStaticItem(title: "Click a thread to open it in Codex. Hold Option to copy its id."))

        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Refresh Threads", action: #selector(refreshThreadsAction)))

        let watchItem = makeActionItem(title: "Watch Latest Thread", action: #selector(watchLatestThreadAction))
        watchItem.isEnabled = !state.recentThreads.isEmpty
        menu.addItem(watchItem)

        menu.addItem(.separator())

        if state.recentThreads.isEmpty {
            menu.addItem(makeStaticItem(title: "No recent threads"))
        } else {
            for thread in state.recentThreads {
                let item = makeActionItem(title: menuTitle(for: thread), action: #selector(openThread(_:)))
                item.representedObject = thread.id
                item.toolTip = "\(thread.preview)\n\(thread.cwd)"
                menu.addItem(item)
            }
        }

        if let diagnostic = state.lastDiagnostic {
            menu.addItem(.separator())
            menu.addItem(makeStaticItem(title: "Last diagnostic: \(diagnostic)"))
        }

        menu.addItem(makeStaticItem(title: "State snapshot: \(state.debugStatusSnapshot)"))
        if let desktopDebugSummary = state.desktopDebugSummary {
            menu.addItem(makeStaticItem(title: "Desktop debug: \(desktopDebugSummary)"))
        }

        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Quit", action: #selector(quit)))
    }

    private func makeStaticItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func makeActionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func menuTitle(for thread: AppStateStore.ThreadRow) -> String {
        let watchMarker = thread.isWatched ? "• " : ""
        let relativeDate = relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
        return "\(watchMarker)\(thread.displayTitle) | \(thread.status.displayName) | \(relativeDate)"
    }

    @objc
    private func refreshThreadsAction() {
        Task {
            do {
                try await refreshThreads()
            } catch {
                state.setConnection(.failed(message: error.localizedDescription))
                renderMenu()
            }
        }
    }

    @objc
    private func watchLatestThreadAction() {
        Task {
            await watchLatestThread()
        }
    }

    @objc
    private func openThread(_ sender: NSMenuItem) {
        guard let threadID = sender.representedObject as? String else { return }

        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            copyThreadID(threadID)
            return
        }

        guard let deepLinkURL = CodexDeepLink.threadURL(threadID: threadID) else {
            state.recordDiagnostic("Unable to build a Codex deeplink for thread \(threadID).")
            renderMenu()
            return
        }

        if NSWorkspace.shared.open(deepLinkURL) {
            return
        }

        guard let appURL = CodexApplicationLocator.locate() else {
            copyThreadID(threadID)
            state.recordDiagnostic("Unable to open Codex deeplink. Copied thread id instead.")
            renderMenu()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appURL.path, deepLinkURL.absoluteString]

        do {
            try task.run()
        } catch {
            copyThreadID(threadID)
            state.recordDiagnostic("Failed to open Codex thread. Copied thread id instead: \(error.localizedDescription)")
            renderMenu()
        }
    }

    private func copyThreadID(_ threadID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(threadID, forType: .string)
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
