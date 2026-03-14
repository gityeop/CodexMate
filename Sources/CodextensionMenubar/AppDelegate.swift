import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RetentionPolicy {
        static let threadReadMarkerSeconds: TimeInterval = 30 * 24 * 60 * 60
        static let pendingDiscoveredThreadSeconds: TimeInterval = 2 * 60
        static let maxPendingDiscoveredThreads = 64
    }

    private enum ThreadListDisplay {
        static let initialFetchLimit = 32
        static let fetchPageLimit = 64
        static let maxTrackedThreads = 256
        static let initialSubscriptionLimit = 8
        static let subscriptionConcurrency = 4
        static let projectLimit = 5
        static let visibleThreadLimit = 8
        static let maxProjectDisplayNameLength = 28
        static let maxThreadDisplayTitleLength = 44
    }

    private enum DefaultsKey {
        static let threadReadMarkers = "threadLastReadTerminalMarkers"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let client = CodexAppServerClient()
    private let desktopActivityService = DesktopActivityService()
    private let desktopStateReader = CodexDesktopStateReader()
    private let projectCatalogReader = CodexDesktopProjectCatalogReader()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForUserIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")
    private let hoverTooltipController = ThreadHoverTooltipController()
    private lazy var recentThreadListing = AppServerRecentThreadListing(
        client: client,
        fetchPageLimit: ThreadListDisplay.fetchPageLimit
    )
    private lazy var controller = MenubarController(
        desktopActivityLoader: desktopActivityService,
        recentThreadListing: recentThreadListing,
        threadMetadataReader: desktopStateReader,
        projectCatalogLoader: projectCatalogReader,
        initialThreadReadMarkers: AppDelegate.loadThreadReadMarkers(),
        configuration: MenubarControllerConfiguration(
            initialFetchLimit: ThreadListDisplay.initialFetchLimit,
            maxTrackedThreads: ThreadListDisplay.maxTrackedThreads,
            projectLimit: ThreadListDisplay.projectLimit,
            visibleThreadLimit: ThreadListDisplay.visibleThreadLimit,
            maxPendingDiscoveredThreads: RetentionPolicy.maxPendingDiscoveredThreads,
            pendingDiscoveredThreadTTL: RetentionPolicy.pendingDiscoveredThreadSeconds,
            threadReadMarkerRetentionSeconds: RetentionPolicy.threadReadMarkerSeconds
        )
    )
    private var liveSubscribedThreadUpdatedAtByID: [String: Date] = [:]
    private var connectedBinaryPath: String?
    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var isMenuOpen = false
    private var lastDesktopActivityRefreshRequestAt: Date?
    private var lastThreadRefreshRequestAt: Date?
    private var desktopActivityRefreshGate = RefreshRequestGate()
    private var desktopActivityRefreshTask: Task<Void, Never>?
    private var threadRefreshGate = RefreshRequestGate()
    private var threadRefreshTask: Task<Void, Never>?
    private var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
    private var hoverTooltipWorkItem: DispatchWorkItem?
    private var highlightedThreadID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.title = controller.overallStatus.icon

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
            controller.recordDiagnostic("User notifications are disabled outside an .app bundle.")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func connectAndLoad() async {
        controller.setConnection(.connecting)
        renderMenu()

        do {
            let binaryURL = try CodexBinaryLocator.locate()
            try await client.start(codexBinaryURL: binaryURL)
            connectedBinaryPath = binaryURL.path
            controller.setConnection(.connected(binaryPath: binaryURL.path))
            renderMenu()

            try await loadInitialThreads()
            scheduleRefreshTimerIfNeeded()
            requestDesktopActivityRefresh()
            requestInitialSubscriptionWarmup()
        } catch {
            controller.setConnection(.failed(message: error.localizedDescription))
            renderMenu()
        }
    }

    private func refreshThreads() async throws {
        let effects = try await controller.refreshThreads()
        markConnectionHealthy()
        applyControllerEffects(effects)
        await reconcileLiveSubscriptions()
        renderMenu()
    }

    private func loadInitialThreads() async throws {
        try await controller.loadInitialThreads()
        markConnectionHealthy()
        renderMenu()
    }

    private func watchLatestThread() async {
        guard let thread = controller.recentThreads.first else { return }

        await resumeThreadSubscriptions([thread.id])
        renderMenu()
    }

    private func handleClientTermination(reason: String?) {
        invalidateTimers()

        let message = reason ?? "app-server process exited"
        controller.setConnection(.failed(message: message))
        renderMenu()
    }

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case let .notification(method, payload):
            handleNotification(method: method, payload: payload)
        case let .request(_, method, payload):
            handleServerRequest(method: method, payload: payload)
        case let .diagnostic(text):
            controller.recordDiagnostic(text)
            renderMenu()
        }
    }

    private func handleNotification(method: String, payload: Data) {
        switch method {
        case "thread/started":
            decodeAndApply(payload, as: ThreadStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .threadStarted(notification))
                debugLog("received thread/started thread=\(shortThreadID(notification.thread.id))")
                requestThreadRefresh()
            }
        case "thread/status/changed":
            decodeAndApply(payload, as: ThreadStatusChangedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .threadStatusChanged(notification))
            }
        case "turn/started":
            decodeAndApply(payload, as: TurnStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .turnStarted(notification))
            }
        case "turn/completed":
            decodeAndApply(payload, as: TurnCompletedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .turnCompleted(notification))
                requestDesktopActivityRefresh()
                sendNotification(
                    title: "Codex turn completed",
                    body: controller.notificationBody(forThreadID: notification.threadId, fallback: notification.turn.status.displayName)
                )
            }
        case "error":
            decodeAndApply(payload, as: ErrorNotificationPayload.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .error(notification))
                requestDesktopActivityRefresh()

                if !notification.willRetry {
                    sendNotification(
                        title: "Codex error",
                        body: controller.notificationBody(forThreadID: notification.threadId, fallback: notification.error.message)
                    )
                }
            }
        case "serverRequest/resolved":
            decodeAndApply(payload, as: ServerRequestResolvedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .serverRequestResolved(notification))
            }
        case "thread/closed":
            decodeAndApply(payload, as: ThreadClosedNotification.self) { [weak self] notification in
                guard let self else { return }
                liveSubscribedThreadUpdatedAtByID.removeValue(forKey: notification.threadId)
                controller.markUnwatched(threadIDs: Set([notification.threadId]))
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
                controller.apply(serverRequest: .toolUserInput(request))
                controller.recordDiagnostic("user-input request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex needs input",
                    body: controller.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for user input.")
                )
            }
        case "item/commandExecution/requestApproval", "commandExecution/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                controller.apply(serverRequest: .approval(request))
                controller.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex approval required",
                    body: controller.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
                )
            }
        case "item/fileChange/requestApproval", "fileChange/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                controller.apply(serverRequest: .approval(request))
                controller.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                sendNotification(
                    title: "Codex approval required",
                    body: controller.notificationBody(forThreadID: request.threadId, fallback: "A watched thread is waiting for approval.")
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

    private func scheduleRefreshTimerIfNeeded() {
        guard case .connected = controller.connection else {
            invalidateTimers()
            return
        }

        let policy = refreshSchedulingPolicy()
        guard refreshTimer == nil || refreshTimerInterval != policy.timerInterval else {
            return
        }

        invalidateTimers()
        refreshTimerInterval = policy.timerInterval
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: policy.timerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleRefreshTimerTick()
            }
        }
    }

    private func refreshSchedulingPolicy() -> RefreshSchedulingPolicy {
        RefreshSchedulingPolicy.current(
            isMenuOpen: isMenuOpen,
            overallStatus: controller.overallStatus
        )
    }

    private func handleRefreshTimerTick(now: Date = Date()) {
        requestDesktopActivityRefresh(force: false, now: now)
        requestThreadRefresh(force: false, now: now)
    }

    private func invalidateTimers() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTimerInterval = nil
    }

    private func refreshDesktopActivity() async {
        let effects = await controller.refreshDesktopActivity()
        applyControllerEffects(effects)
        renderMenu()
    }

    private func markConnectionHealthy() {
        guard let connectedBinaryPath else { return }
        controller.setConnection(.connected(binaryPath: connectedBinaryPath))
    }

    private func renderMenu() {
        hoverTooltipWorkItem?.cancel()
        hoverTooltipWorkItem = nil

        let preparedSnapshot = controller.prepareSnapshot(
            additionalTrackedThreadIDs: Set(liveSubscribedThreadUpdatedAtByID.keys)
        )
        if preparedSnapshot.didChangeReadMarkers {
            persistThreadReadMarkers()
        }

        let snapshot = preparedSnapshot.snapshot
        statusItem.button?.title = MenubarStatusPresentation.statusItemIcon(
            overallStatus: snapshot.overallStatus,
            hasUnreadThreads: snapshot.hasUnreadThreads
        )
        var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
        menu.removeAllItems()

        if snapshot.projectSections.isEmpty {
            menu.addItem(makeStaticItem(title: "No recent threads"))
        } else {
            for (index, section) in snapshot.projectSections.enumerated() {
                if index > 0 {
                    menu.addItem(.separator())
                }

                let item = makeStaticItem(title: projectSectionTitle(for: section.section))
                menu.addItem(item)

                for thread in section.threads {
                    let tooltipContent = MenubarStatusPresentation.threadTooltipContent(
                        worktreeDisplayName: section.section.displayName,
                        thread: thread.thread
                    )
                    let item = makeActionItem(title: menuTitle(for: thread.thread), action: #selector(openThread(_:)))
                    item.representedObject = thread.id
                    item.image = indicatorImage(for: thread)
                    item.toolTip = nil
                    hoverTooltipContentsByThreadID[thread.id] = tooltipContent
                    menu.addItem(item)
                }
            }
        }

        self.hoverTooltipContentsByThreadID = hoverTooltipContentsByThreadID
        if let highlightedThreadID,
           let tooltipContent = hoverTooltipContentsByThreadID[highlightedThreadID],
           hoverTooltipController.isVisible {
            hoverTooltipController.show(
                content: tooltipContent,
                near: NSEvent.mouseLocation,
                avoidingMenuWidth: menu.size.width,
                menuFrame: currentMenuFrame()
            )
        } else if highlightedThreadID != nil && hoverTooltipController.isVisible {
            hideHoverTooltip()
        }
        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Refresh Threads", action: #selector(refreshThreadsAction)))

        let watchItem = makeActionItem(title: "Watch Latest Thread", action: #selector(watchLatestThreadAction))
        watchItem.isEnabled = snapshot.isWatchLatestThreadEnabled
        menu.addItem(watchItem)

        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Quit", action: #selector(quit)))
        scheduleRefreshTimerIfNeeded()
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
        return MenubarStatusPresentation.threadTitle(
            for: thread,
            relativeDate: relativeDate,
            maxDisplayTitleLength: ThreadListDisplay.maxThreadDisplayTitleLength
        )
    }

    private func indicatorImage(for thread: MenubarThreadSnapshot) -> NSImage? {
        switch MenubarStatusPresentation.threadIndicator(for: thread.thread, hasUnreadContent: thread.hasUnreadContent) {
        case .unread:
            return unreadIndicatorImage
        case .running:
            return runningIndicatorImage
        case .waitingForUser:
            return waitingForUserIndicatorImage
        case .failed:
            return failedIndicatorImage
        case nil:
            return nil
        }
    }

    private func projectSectionTitle(for section: AppStateStore.ProjectSection) -> String {
        MenubarStatusPresentation.projectSectionTitle(
            displayName: section.displayName,
            threadCount: section.threads.count,
            maxDisplayNameLength: ThreadListDisplay.maxProjectDisplayNameLength
        )
    }

    private func updateHoverTooltip(for item: NSMenuItem?) {
        guard let threadID = item?.representedObject as? String,
              let tooltipContent = hoverTooltipContentsByThreadID[threadID] else {
            hideHoverTooltip()
            return
        }

        hoverTooltipWorkItem?.cancel()

        if highlightedThreadID == threadID, hoverTooltipController.isVisible {
            hoverTooltipController.show(
                content: tooltipContent,
                near: NSEvent.mouseLocation,
                avoidingMenuWidth: menu.size.width,
                menuFrame: currentMenuFrame()
            )
            return
        }

        highlightedThreadID = threadID
        let delay: TimeInterval = hoverTooltipController.isVisible ? 0.08 : 0.18
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.highlightedThreadID == threadID else { return }
            self.hoverTooltipController.show(
                content: tooltipContent,
                near: NSEvent.mouseLocation,
                avoidingMenuWidth: self.menu.size.width,
                menuFrame: self.currentMenuFrame()
            )
        }
        hoverTooltipWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func currentMenuFrame() -> NSRect? {
        let frame = menu.accessibilityFrame()
        guard !frame.isEmpty else { return nil }
        return frame
    }

    private func hideHoverTooltip() {
        hoverTooltipWorkItem?.cancel()
        hoverTooltipWorkItem = nil
        highlightedThreadID = nil
        hoverTooltipController.hide()
    }

    private func markThreadRead(_ threadID: String) {
        if controller.markThreadRead(threadID) {
            persistThreadReadMarkers()
        }
    }

    private func persistThreadReadMarkers() {
        UserDefaults.standard.set(controller.persistedThreadReadMarkers, forKey: DefaultsKey.threadReadMarkers)
    }

    private func debugLog(_ message: String) {
        let line = "[CodextensionMenubar] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        controller.recordDiagnostic(message)
    }

    private func applyControllerEffects(_ effects: MenubarControllerEffects) {
        for diagnostic in effects.diagnostics {
            debugLog(diagnostic)
        }

        if effects.shouldRequestDesktopActivityRefresh {
            requestDesktopActivityRefresh()
        }

        if effects.shouldRequestThreadRefresh {
            requestThreadRefresh()
        }
    }

    private func shortThreadID(_ threadID: String) -> String {
        String(threadID.prefix(8))
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
        controller.visibleProjectSections()
    }

    private func requestThreadRefresh(force: Bool = true, now: Date = Date()) {
        if !force {
            let policy = refreshSchedulingPolicy()
            guard policy.shouldRefreshThreadList(now: now, lastRequestedAt: lastThreadRefreshRequestAt) else {
                return
            }
        }

        lastThreadRefreshRequestAt = now
        guard threadRefreshGate.beginOrQueue() else {
            return
        }

        threadRefreshTask = Task { @MainActor in
            defer {
                threadRefreshTask = nil
                if threadRefreshGate.finish() {
                    requestThreadRefresh()
                }
            }

            do {
                try await refreshThreads()
            } catch {
                controller.setConnection(.failed(message: error.localizedDescription))
                renderMenu()
            }
        }
    }

    private func requestDesktopActivityRefresh(force: Bool = true, now: Date = Date()) {
        if !force {
            let policy = refreshSchedulingPolicy()
            guard policy.shouldRefreshDesktopActivity(now: now, lastRequestedAt: lastDesktopActivityRefreshRequestAt) else {
                return
            }
        }

        lastDesktopActivityRefreshRequestAt = now
        guard desktopActivityRefreshGate.beginOrQueue() else {
            return
        }

        desktopActivityRefreshTask = Task { @MainActor in
            defer {
                desktopActivityRefreshTask = nil
                if desktopActivityRefreshGate.finish() {
                    requestDesktopActivityRefresh()
                }
            }

            await refreshDesktopActivity()
        }
    }

    private func requestInitialSubscriptionWarmup() {
        Task { @MainActor [weak self] in
            await self?.warmInitialSubscriptions()
        }
    }

    private func reconcileLiveSubscriptions() async {
        let plan = ThreadSubscriptionPlanner.makePlan(
            recentThreads: controller.recentThreads,
            liveThreadUpdatedAtByID: liveSubscribedThreadUpdatedAtByID,
            maxSubscribedThreads: ThreadListDisplay.maxTrackedThreads
        )

        if !plan.threadIDsToUnsubscribe.isEmpty {
            await unsubscribeThreadSubscriptions(plan.threadIDsToUnsubscribe)
        }

        if !plan.threadIDsToResume.isEmpty {
            await resumeThreadSubscriptions(plan.threadIDsToResume)
        }
    }

    private func warmInitialSubscriptions() async {
        let threadIDs = initialWarmSubscriptionThreadIDs()
        guard !threadIDs.isEmpty else {
            return
        }

        await resumeThreadSubscriptions(threadIDs)
        renderMenu()
    }

    private func initialWarmSubscriptionThreadIDs() -> [String] {
        let visibleThreadIDs = visibleProjectSections()
            .flatMap(\.threads)
            .map(\.id)

        let candidates = visibleThreadIDs.isEmpty ? controller.recentThreads.map(\.id) : visibleThreadIDs
        var seenThreadIDs: Set<String> = Set(liveSubscribedThreadUpdatedAtByID.keys)
        var threadIDsToResume: [String] = []

        for threadID in candidates {
            guard !seenThreadIDs.contains(threadID) else {
                continue
            }

            seenThreadIDs.insert(threadID)
            threadIDsToResume.append(threadID)

            if threadIDsToResume.count == ThreadListDisplay.initialSubscriptionLimit {
                break
            }
        }

        return threadIDsToResume
    }

    private func resumeThreadSubscriptions(_ threadIDs: [String]) async {
        guard !threadIDs.isEmpty else {
            return
        }

        let client = self.client
        let results = await batchedThreadRequests(threadIDs: threadIDs) { threadID in
            do {
                let response: ThreadResumeResponse = try await client.call(
                    method: "thread/resume",
                    params: ThreadResumeParams(threadId: threadID, persistExtendedHistory: false)
                )

                return (threadID: threadID, thread: Optional(response.thread), errorMessage: Optional<String>.none)
            } catch {
                return (threadID: threadID, thread: Optional<CodexThread>.none, errorMessage: error.localizedDescription)
            }
        }

        for result in results {
            if let thread = result.thread {
                markConnectionHealthy()
                liveSubscribedThreadUpdatedAtByID[thread.id] = thread.updatedDate
                controller.markWatched(thread: thread)
            } else if let errorMessage = result.errorMessage {
                controller.recordDiagnostic("Failed to resume thread \(result.threadID.prefix(8)): \(errorMessage)")
            }
        }
    }

    private func unsubscribeThreadSubscriptions(_ threadIDs: [String]) async {
        guard !threadIDs.isEmpty else {
            return
        }

        let client = self.client
        let results = await batchedThreadRequests(threadIDs: threadIDs) { threadID in
            do {
                let response: ThreadUnsubscribeResponse = try await client.call(
                    method: "thread/unsubscribe",
                    params: ThreadUnsubscribeParams(threadId: threadID)
                )

                return (threadID: threadID, responseStatus: Optional(response.status), errorMessage: Optional<String>.none)
            } catch {
                return (threadID: threadID, responseStatus: Optional<String>.none, errorMessage: error.localizedDescription)
            }
        }

        for result in results {
            if let status = result.responseStatus {
                liveSubscribedThreadUpdatedAtByID.removeValue(forKey: result.threadID)
                if ["unsubscribed", "notSubscribed", "notLoaded"].contains(status) {
                    controller.markUnwatched(threadIDs: Set([result.threadID]))
                }
            } else if let errorMessage = result.errorMessage {
                controller.recordDiagnostic("Failed to unsubscribe thread \(result.threadID.prefix(8)): \(errorMessage)")
            }
        }
    }

    private func batchedThreadRequests<Result: Sendable>(
        threadIDs: [String],
        operation: @escaping @Sendable (String) async -> Result
    ) async -> [Result] {
        var results: [Result] = []
        var index = 0

        while index < threadIDs.count {
            let upperBound = min(index + ThreadListDisplay.subscriptionConcurrency, threadIDs.count)
            let batch = Array(threadIDs[index..<upperBound])

            let batchResults = await withTaskGroup(of: (Int, Result).self) { group in
                for (offset, threadID) in batch.enumerated() {
                    group.addTask {
                        (offset, await operation(threadID))
                    }
                }

                var collected: [(Int, Result)] = []
                for await result in group {
                    collected.append(result)
                }

                return collected
                    .sorted { $0.0 < $1.0 }
                    .map(\.1)
            }

            results.append(contentsOf: batchResults)
            index = upperBound
        }

        return results
    }

    @objc
    private func refreshThreadsAction() {
        requestDesktopActivityRefresh()
        requestThreadRefresh()
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
            controller.recordDiagnostic("Unable to build a Codex deeplink for thread \(threadID).")
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
            controller.recordDiagnostic("Unable to open Codex deeplink. Copied thread id instead.")
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
            controller.recordDiagnostic("Failed to open Codex thread. Copied thread id instead: \(error.localizedDescription)")
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

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu == self.menu else { return }

        hideHoverTooltip()
        isMenuOpen = true
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh()
        requestThreadRefresh()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu == self.menu else { return }

        updateHoverTooltip(for: item)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu == self.menu else { return }

        hideHoverTooltip()
        isMenuOpen = false
        scheduleRefreshTimerIfNeeded()
    }
}
