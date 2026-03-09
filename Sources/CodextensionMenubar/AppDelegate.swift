import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RefreshInterval {
        static let desktopActivitySeconds: TimeInterval = 1
        static let threadListSeconds: TimeInterval = 2
        static let statusIconFrameSeconds: TimeInterval = 0.12
    }

    private static let spriteSheetIconPath = "/Users/tester/Downloads/sprite_sheet_codash.png"
    private static let statusItemIconPath = "/Users/tester/Downloads/codash.png"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let utilityMenu = NSMenu()
    private let client = CodexAppServerClient()
    private let desktopStateReader = CodexDesktopStateReader()
    private let desktopProjectStateReader = CodexDesktopProjectStateReader()
    private let panelController = MonochromePanelController()
    private let statusBadgeField = StatusItemBadgeField()

    private var state = AppStateStore()
    private var statusIconAnimator: StatusItemSpriteAnimator?
    private var statusIconTimer: Timer?
    private var desktopActivityTimer: Timer?
    private var threadListTimer: Timer?
    private var isRefreshingThreads = false
    private var pendingThreadRefresh = false
    private var recentDebugEntries: [String] = []
    private var lastDebugSnapshotLine: String?
    private var lastStatusDebugLine: String?
    private var hasInstalledStatusBadge = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        configureUtilityMenu()
        configurePanelCallbacks()
        configureClientCallbacks()
        requestNotificationPermission()

        recordDebug("Application launched.")
        renderInterface()

        Task {
            await connectAndLoad()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusIconTimer?.invalidate()
        statusIconTimer = nil
        invalidateTimers()
        panelController.close()

        Task {
            await client.stop()
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(handleStatusItemPress(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseDown])

        installStatusBadgeIfNeeded(on: button)
        statusIconAnimator = StatusItemSpriteAnimator(
            spriteSheetURL: URL(fileURLWithPath: Self.spriteSheetIconPath),
            fallbackIconURL: URL(fileURLWithPath: Self.statusItemIconPath)
        )
        startStatusIconTimer()
    }

    private func configureUtilityMenu() {
        utilityMenu.autoenablesItems = false
        utilityMenu.addItem(makeActionItem(title: "Refresh", action: #selector(refreshThreadsAction)))
        utilityMenu.addItem(makeActionItem(title: "Copy Debug Log", action: #selector(copyDebugLogAction)))
        utilityMenu.addItem(.separator())
        utilityMenu.addItem(makeActionItem(title: "Quit", action: #selector(quit)))
    }

    private func configurePanelCallbacks() {
        panelController.onRefresh = { [weak self] in
            self?.queueThreadRefresh()
        }

        panelController.onThreadSelected = { [weak self] threadID, copyOnly in
            guard let self else { return }

            if copyOnly {
                copyThreadID(threadID)
            } else {
                openThreadByID(threadID)
            }
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
        recordDebug("Connecting to Codex app-server.")
        renderInterface()

        do {
            let binaryURL = try CodexBinaryLocator.locate()
            try await client.start(codexBinaryURL: binaryURL)
            state.setConnection(.connected(binaryPath: binaryURL.path))
            recordDebug("Connected to Codex binary at \(binaryURL.path).")
            renderInterface()

            try await refreshThreadsNow()
            scheduleRefreshTimers()
        } catch {
            state.setConnection(.failed(message: error.localizedDescription))
            recordDebug("Connection failed: \(error.localizedDescription)")
            renderInterface()
        }
    }

    private func refreshThreadsNow() async throws {
        let response: ThreadListResponse = try await client.call(
            method: "thread/list",
            params: ThreadListParams(limit: 100, archived: false)
        )

        refreshProjectCatalog()
        let debugMessages = state.replaceRecentThreads(with: response.data)
        applyDesktopRuntimeOverlay()
        recordDebug(
            "thread/list returned \(response.data.count) threads. actionable=\(state.actionableThreadCount) projects=\(state.panelProjects.count)"
        )
        for message in debugMessages {
            recordDebug(message)
        }
        renderInterface()
    }

    private func queueThreadRefresh() {
        pendingThreadRefresh = true

        guard !isRefreshingThreads else { return }

        Task { @MainActor [weak self] in
            await self?.drainThreadRefreshQueue()
        }
    }

    private func drainThreadRefreshQueue() async {
        guard !isRefreshingThreads else { return }

        isRefreshingThreads = true
        defer { isRefreshingThreads = false }

        while pendingThreadRefresh {
            pendingThreadRefresh = false

            do {
                try await refreshThreadsNow()
            } catch {
                state.setConnection(.failed(message: error.localizedDescription))
                recordDebug("thread refresh failed: \(error.localizedDescription)")
                renderInterface()
            }
        }
    }

    private func handleClientTermination(reason: String?) {
        invalidateTimers()

        let message = reason ?? "app-server process exited"
        state.setConnection(.failed(message: message))
        recordDebug("Client terminated: \(message)")
        renderInterface()
    }

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case let .notification(method, payload):
            handleNotification(method: method, payload: payload)
        case let .request(_, method, payload):
            handleServerRequest(method: method, payload: payload)
        case let .diagnostic(text):
            state.recordDiagnostic(text)
            renderInterface()
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
                recordDebug("thread status changed thread=\(notification.threadId)")
                state.apply(notification: .threadStatusChanged(notification))
            }
        case "turn/started":
            decodeAndApply(payload, as: TurnStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                recordDebug("turn started thread=\(notification.threadId) turn=\(notification.turn.id)")
                state.apply(notification: .turnStarted(notification))
            }
        case "turn/completed":
            decodeAndApply(payload, as: TurnCompletedNotification.self) { [weak self] notification in
                guard let self else { return }
                recordDebug("turn completed thread=\(notification.threadId) turn=\(notification.turn.id) status=\(notification.turn.status.displayName)")
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

        renderInterface()
    }

    private func handleServerRequest(method: String, payload: Data) {
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            decodeAndApply(payload, as: ToolRequestUserInputRequest.self) { [weak self] request in
                guard let self else { return }
                recordDebug("user input request method=\(method) thread=\(request.threadId) turn=\(request.turnId)")
                state.apply(serverRequest: .toolUserInput(request))
                sendNotification(
                    title: "Codex needs input",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for user input.")
                )
            }
        case "item/commandExecution/requestApproval", "commandExecution/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                recordDebug("approval request method=\(method) thread=\(request.threadId) turn=\(request.turnId)")
                state.apply(serverRequest: .approval(request))
                sendNotification(
                    title: "Codex approval required",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
                )
            }
        case "item/fileChange/requestApproval", "fileChange/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                recordDebug("approval request method=\(method) thread=\(request.threadId) turn=\(request.turnId)")
                state.apply(serverRequest: .approval(request))
                sendNotification(
                    title: "Codex approval required",
                    body: state.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
                )
            }
        default:
            break
        }

        renderInterface()
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
            Task { @MainActor [weak self] in
                self?.queueThreadRefresh()
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
        let didChange = applyDesktopRuntimeOverlay()
        renderInterface()

        if didChange {
            queueThreadRefresh()
        }
    }

    @discardableResult
    private func applyDesktopRuntimeOverlay() -> Bool {
        let candidateThreadIDs = Set(state.recentThreads.map(\.id))
        let previousTurnCount = state.desktopActiveTurnCount
        let previousRunningThreadIDs = state.desktopRunningThreadIDs
        let previousInProgressActivity = state.desktopHasInProgressActivity
        let previousLastEvent = state.desktopLastAppServerEvent

        do {
            let snapshot = try desktopStateReader.snapshot(candidates: candidateThreadIDs)
            state.apply(desktopSnapshot: snapshot)
            let didChange = previousTurnCount != snapshot.activeTurnCount
                || previousRunningThreadIDs != snapshot.runningThreadIDs
                || previousInProgressActivity != snapshot.hasInProgressActivity
                || previousLastEvent != snapshot.lastAppServerEvent

            if didChange {
                let lastEvent = snapshot.lastAppServerEvent ?? "none"
                recordDebug(
                    "desktop snapshot turns=\(snapshot.activeTurnCount) runningIDs=\(snapshot.runningThreadIDs.count) inProgress=\(snapshot.hasInProgressActivity) lastEvent=\(lastEvent)"
                )
            }

            return didChange
        } catch {
            state.recordDiagnostic("Desktop activity unavailable: \(error.localizedDescription)")
            recordDebug("desktop snapshot failed: \(error.localizedDescription)")
            return false
        }
    }

    private func refreshProjectCatalog() {
        do {
            state.setProjectCatalog(try desktopProjectStateReader.readCatalog())
            recordDebug("Loaded \(state.savedProjectCount) saved projects from Codex state.")
        } catch {
            state.recordDiagnostic("Project names unavailable: \(error.localizedDescription)")
            recordDebug("Project catalog load failed: \(error.localizedDescription)")
        }
    }

    private func renderInterface() {
        renderStatusItem()

        if panelController.isVisible {
            panelController.update(model: panelModel)
        }

        maybeRecordRenderSnapshot()
    }

    private func renderStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = currentStatusItemImage(advanceFrame: false)
        button.toolTip = statusItemTooltip

        let badgeText = badgeText(for: state.actionableThreadCount)
        statusBadgeField.isHidden = badgeText == nil
        statusBadgeField.stringValue = badgeText ?? ""
        statusBadgeField.invalidateIntrinsicContentSize()
    }

    private func installStatusBadgeIfNeeded(on button: NSStatusBarButton) {
        guard !hasInstalledStatusBadge else { return }

        statusBadgeField.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeField.isHidden = true
        button.addSubview(statusBadgeField)

        NSLayoutConstraint.activate([
            statusBadgeField.topAnchor.constraint(equalTo: button.topAnchor, constant: 2),
            statusBadgeField.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
        ])

        hasInstalledStatusBadge = true
    }

    private func startStatusIconTimer() {
        statusIconTimer?.invalidate()
        statusIconTimer = Timer.scheduledTimer(
            withTimeInterval: RefreshInterval.statusIconFrameSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.advanceStatusItemFrame()
            }
        }
    }

    private func advanceStatusItemFrame() {
        guard let button = statusItem.button else { return }
        button.image = currentStatusItemImage(advanceFrame: true)
    }

    private func currentStatusItemImage(advanceFrame: Bool) -> NSImage? {
        if let statusIconAnimator {
            let mode = state.statusIconAnimationMode
            if let image = advanceFrame
                ? statusIconAnimator.advance(mode: mode)
                : statusIconAnimator.currentImage(mode: mode) {
                return image
            }
        }

        if let fallback = NSImage(contentsOf: URL(fileURLWithPath: Self.statusItemIconPath)) {
            fallback.size = NSSize(width: 18, height: 18)
            fallback.isTemplate = false
            return fallback
        }

        let symbol = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        symbol?.isTemplate = true
        return symbol
    }

    private var statusItemTooltip: String {
        if state.actionableThreadCount > 0 {
            return "\(state.actionableThreadCount) item(s) need attention"
        }

        return panelSummaryLine
    }

    private func badgeText(for actionableCount: Int) -> String? {
        guard actionableCount > 0 else { return nil }
        if actionableCount > 99 {
            return "99+"
        }

        return "\(actionableCount)"
    }

    private var panelModel: MonochromePanelController.Model {
        MonochromePanelController.Model(
            title: appDisplayName,
            subtitle: panelSummaryLine,
            bannerText: panelBannerText,
            projects: state.panelProjects
        )
    }

    private var appDisplayName: String {
        let bundle = Bundle.main
        if let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
            return displayName
        }

        if let name = bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String, !name.isEmpty {
            return name
        }

        return "Codextension"
    }

    private var panelSummaryLine: String {
        let actionableCount = state.actionableThreadCount
        if actionableCount > 0 {
            let label = actionableCount == 1 ? "item needs" : "items need"
            return "\(actionableCount) \(label) attention"
        }

        switch state.overallStatus {
        case .connecting:
            return "Connecting to Codex"
        case .running:
            return "Tracking active work"
        case .waitingForInput:
            return "Waiting for your reply"
        case .needsApproval:
            return "Approval required"
        case .failed:
            return "Connection issue"
        case .idle:
            if state.panelProjects.isEmpty {
                return "No recent threads yet"
            }
            return "All clear"
        }
    }

    private var panelBannerText: String? {
        switch state.connection {
        case .failed(let message):
            return message
        case .connecting:
            return "Connecting to Codex app-server…"
        case .disconnected:
            return "Not connected to Codex."
        case .connected:
            return nil
        }
    }

    private func showUtilityMenu(relativeTo button: NSStatusBarButton) {
        utilityMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func makeActionItem(title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc
    private func handleStatusItemPress(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        let isRightClick = event.type == .rightMouseUp
            || event.type == .rightMouseDown
            || (event.type == .leftMouseUp && event.modifierFlags.contains(.control))
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))

        recordDebug(
            "status item click type=\(event.type.rawValue) rightClick=\(isRightClick) panelVisible=\(panelController.isVisible)"
        )

        if isRightClick {
            showUtilityMenu(relativeTo: sender)
            return
        }

        recordDebug("queueing panel toggle")
        DispatchQueue.main.async { [weak self, weak sender] in
            guard let self, let sender else { return }
            NSApp.activate(ignoringOtherApps: true)
            panelController.toggle(relativeTo: sender, model: panelModel)
            recordDebug("panel toggled visible=\(panelController.isVisible)")
            renderInterface()
        }
    }

    @objc
    private func refreshThreadsAction() {
        queueThreadRefresh()
    }

    @objc
    private func copyDebugLogAction() {
        let contents = recentDebugEntries.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
    }

    private func openThreadByID(_ threadID: String) {
        guard let deepLinkURL = CodexDeepLink.threadURL(threadID: threadID) else {
            state.recordDiagnostic("Unable to build a Codex deeplink for thread \(threadID).")
            renderInterface()
            return
        }

        if NSWorkspace.shared.open(deepLinkURL) {
            return
        }

        guard let appURL = CodexApplicationLocator.locate() else {
            copyThreadID(threadID)
            state.recordDiagnostic("Unable to open Codex deeplink. Copied thread id instead.")
            renderInterface()
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
            renderInterface()
        }
    }

    private func copyThreadID(_ threadID: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(threadID, forType: .string)
    }

    private func maybeRecordRenderSnapshot() {
        let snapshot = "render status=\(state.overallStatus.displayName) actionable=\(state.actionableThreadCount) projects=\(state.panelProjects.count) panelVisible=\(panelController.isVisible)"
        if snapshot != lastDebugSnapshotLine {
            lastDebugSnapshotLine = snapshot
            recordDebug(snapshot)
        }

        let statusSnapshot = "thread statuses \(state.debugTrackedStatusSummary)"
        if statusSnapshot != lastStatusDebugLine {
            lastStatusDebugLine = statusSnapshot
            recordDebug(statusSnapshot)
        }
    }

    private func recordDebug(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        recentDebugEntries.append(line)

        if recentDebugEntries.count > 40 {
            recentDebugEntries.removeFirst(recentDebugEntries.count - 40)
        }

        if let data = (line + "\n").data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
    }
}
