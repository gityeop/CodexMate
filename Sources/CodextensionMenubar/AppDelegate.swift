import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RefreshInterval {
        static let desktopActivitySeconds: TimeInterval = 1
        static let threadListSeconds: TimeInterval = 2
    }

    private enum ThreadListDisplay {
        static let fetchLimit = 64
        static let projectLimit = 5
        static let visibleThreadLimit = 8
    }

    private enum DefaultsKey {
        static let threadReadMarkers = "threadLastReadTerminalMarkers"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let client = CodexAppServerClient()
    private let desktopStateReader = CodexDesktopStateReader()
    private let projectCatalogReader = CodexDesktopProjectCatalogReader()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForInputIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let approvalIndicatorImage = AppDelegate.makeTextIndicatorImage("🟡")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")

    private var state = AppStateStore()
    private var projectCatalog = CodexDesktopProjectCatalog.empty
    private var threadReadMarkers = ThreadReadMarkerStore(lastReadTerminalAtByThreadID: AppDelegate.loadThreadReadMarkers())
    private var resumedVisibleThreadIDs: Set<String> = []
    private var connectedBinaryPath: String?
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
            connectedBinaryPath = binaryURL.path
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
            params: ThreadListParams(limit: ThreadListDisplay.fetchLimit, archived: false)
        )

        markConnectionHealthy()
        projectCatalog = (try? projectCatalogReader.load()) ?? .empty
        state.replaceRecentThreads(with: response.data)
        applyDesktopRuntimeOverlay()
        await resumeVisibleThreadsIfNeeded()
        renderMenu()
    }

    private func watchLatestThread() async {
        guard let thread = state.recentThreads.first else { return }

        do {
            let response: ThreadResumeResponse = try await client.call(
                method: "thread/resume",
                params: ThreadResumeParams(threadId: thread.id, persistExtendedHistory: false)
            )

            markConnectionHealthy()
            state.markWatched(thread: response.thread)
            resumedVisibleThreadIDs.insert(response.thread.id)
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

    private func markConnectionHealthy() {
        guard let connectedBinaryPath else { return }
        state.setConnection(.connected(binaryPath: connectedBinaryPath))
    }

    private func renderMenu() {
        synchronizeThreadReadMarkers()
        let hasUnreadThreads = state.recentThreads.contains(where: hasUnreadContent)
        statusItem.button?.title = MenubarStatusPresentation.statusItemIcon(
            overallStatus: state.overallStatus,
            hasUnreadThreads: hasUnreadThreads
        )
        menu.removeAllItems()

        menu.addItem(makeStaticItem(title: "Status: \(MenubarStatusPresentation.statusDisplayName(overallStatus: state.overallStatus, hasUnreadThreads: hasUnreadThreads))"))
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
            let sections = visibleProjectSections()

            for (index, section) in sections.enumerated() {
                if index > 0 {
                    menu.addItem(.separator())
                }

                menu.addItem(makeStaticItem(title: projectSectionTitle(for: section)))

                for thread in section.threads {
                    let item = makeActionItem(title: menuTitle(for: thread), action: #selector(openThread(_:)))
                    item.representedObject = thread.id
                    item.image = indicatorImage(for: thread)
                    item.toolTip = tooltip(for: thread)
                    menu.addItem(item)
                }
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
        let relativeDate = relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
        return MenubarStatusPresentation.threadTitle(for: thread, relativeDate: relativeDate)
    }

    private func hasUnreadContent(for thread: AppStateStore.ThreadRow) -> Bool {
        threadReadMarkers.hasUnreadContent(threadID: thread.id, lastTerminalActivityAt: thread.lastTerminalActivityAt)
    }

    private func indicatorImage(for thread: AppStateStore.ThreadRow) -> NSImage? {
        let hasUnread = hasUnreadContent(for: thread)

        switch MenubarStatusPresentation.threadIndicator(for: thread, hasUnreadContent: hasUnread) {
        case .unread:
            return unreadIndicatorImage
        case .running:
            return runningIndicatorImage
        case .waitingForInput:
            return waitingForInputIndicatorImage
        case .needsApproval:
            return approvalIndicatorImage
        case .failed:
            return failedIndicatorImage
        case nil:
            return nil
        }
    }

    private func projectSectionTitle(for section: AppStateStore.ProjectSection) -> String {
        let threadCount = section.threads.count
        let suffix = threadCount == 1 ? "thread" : "threads"
        return "\(section.displayName) | \(threadCount) \(suffix)"
    }

    private func tooltip(for thread: AppStateStore.ThreadRow) -> String {
        var lines: [String] = []

        if case let .failed(message?) = thread.displayStatus {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                lines.append("Error: \(trimmed)")
            }
        }

        lines.append(thread.preview)
        lines.append(thread.cwd)
        return lines.joined(separator: "\n")
    }

    private func synchronizeThreadReadMarkers() {
        var didChange = false

        for thread in state.recentThreads {
            if threadReadMarkers.seedIfNeeded(threadID: thread.id) {
                didChange = true
            }
        }

        if didChange {
            persistThreadReadMarkers()
        }
    }

    private func markThreadRead(_ threadID: String) {
        guard let thread = state.recentThreads.first(where: { $0.id == threadID }) else {
            return
        }

        if threadReadMarkers.markRead(threadID: threadID, lastTerminalActivityAt: thread.lastTerminalActivityAt) {
            persistThreadReadMarkers()
        }
    }

    private func persistThreadReadMarkers() {
        UserDefaults.standard.set(threadReadMarkers.lastReadTerminalAtByThreadID, forKey: DefaultsKey.threadReadMarkers)
    }

    private static func loadThreadReadMarkers() -> [String: TimeInterval] {
        let rawDictionary = UserDefaults.standard.dictionary(forKey: DefaultsKey.threadReadMarkers) ?? [:]
        return rawDictionary.reduce(into: [:]) { result, element in
            guard let timestamp = element.value as? NSNumber else {
                return
            }

            result[element.key] = timestamp.doubleValue
        }
    }

    private static func makeUnreadIndicatorImage() -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    private static func makeTextIndicatorImage(_ text: String) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .paragraphStyle: paragraphStyle
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        image.lockFocus()
        text.draw(in: textRect, withAttributes: attributes)
        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    private func visibleProjectSections() -> [AppStateStore.ProjectSection] {
        state.projectSections(
            using: projectCatalog,
            maxProjects: ThreadListDisplay.projectLimit,
            maxThreads: ThreadListDisplay.visibleThreadLimit
        )
    }

    private func resumeVisibleThreadsIfNeeded() async {
        let threadIDsToResume = VisibleThreadResumePlanner.threadIDsToResume(
            from: visibleProjectSections(),
            excluding: resumedVisibleThreadIDs
        )

        guard !threadIDsToResume.isEmpty else {
            return
        }

        for threadID in threadIDsToResume {
            do {
                let response: ThreadResumeResponse = try await client.call(
                    method: "thread/resume",
                    params: ThreadResumeParams(threadId: threadID, persistExtendedHistory: false)
                )

                markConnectionHealthy()
                resumedVisibleThreadIDs.insert(response.thread.id)
                state.markWatched(thread: response.thread)
            } catch {
                state.recordDiagnostic("Failed to resume visible thread \(threadID.prefix(8)): \(error.localizedDescription)")
            }
        }
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
            markThreadRead(threadID)
            renderMenu()
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
            markThreadRead(threadID)
            renderMenu()
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
