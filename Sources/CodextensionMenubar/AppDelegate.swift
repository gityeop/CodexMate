import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RefreshInterval {
        static let desktopActivitySeconds: TimeInterval = 1
        static let threadListSeconds: TimeInterval = 1
    }

    private enum ThreadListDisplay {
        static let initialFetchLimit = 32
        static let fetchPageLimit = 64
        static let maxTrackedThreads = 256
        static let initialSubscriptionLimit = 8
        static let subscriptionConcurrency = 4
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
    private let desktopActivityService = DesktopActivityService()
    private let projectCatalogReader = CodexDesktopProjectCatalogReader()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForUserIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")

    private var state = AppStateStore()
    private var projectCatalog = CodexDesktopProjectCatalog.empty
    private var threadReadMarkers = ThreadReadMarkerStore(lastReadTerminalAtByThreadID: AppDelegate.loadThreadReadMarkers())
    private var liveSubscribedThreadUpdatedAtByID: [String: Date] = [:]
    private var connectedBinaryPath: String?
    private var desktopActivityTimer: Timer?
    private var threadListTimer: Timer?
    private var desktopActivityRefreshTask: Task<Void, Never>?
    private var threadRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
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

            try await loadInitialThreads()
            scheduleRefreshTimers()
            requestDesktopActivityRefresh()
            requestInitialSubscriptionWarmup()
        } catch {
            state.setConnection(.failed(message: error.localizedDescription))
            renderMenu()
        }
    }

    private func refreshThreads() async throws {
        let threads = try await fetchRecentThreads(limit: ThreadListDisplay.maxTrackedThreads)
        projectCatalog = (try? projectCatalogReader.load()) ?? .empty
        state.replaceRecentThreads(with: threads)
        await refreshDesktopActivity()
        await reconcileLiveSubscriptions()
        renderMenu()
    }

    private func loadInitialThreads() async throws {
        let threads = try await fetchRecentThreads(limit: ThreadListDisplay.initialFetchLimit)
        projectCatalog = (try? projectCatalogReader.load()) ?? .empty
        state.replaceRecentThreads(with: threads)
        renderMenu()
    }

    private func watchLatestThread() async {
        guard let thread = state.recentThreads.first else { return }

        await resumeThreadSubscriptions([thread.id])
        renderMenu()
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
        case "serverRequest/resolved":
            decodeAndApply(payload, as: ServerRequestResolvedNotification.self) { [weak self] notification in
                guard let self else { return }
                state.apply(notification: .serverRequestResolved(notification))
            }
        case "thread/closed":
            decodeAndApply(payload, as: ThreadClosedNotification.self) { [weak self] notification in
                guard let self else { return }
                liveSubscribedThreadUpdatedAtByID.removeValue(forKey: notification.threadId)
                state.markUnwatched(threadIDs: Set([notification.threadId]))
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
                self?.requestDesktopActivityRefresh()
            }
        }

        threadListTimer = Timer.scheduledTimer(
            withTimeInterval: RefreshInterval.threadListSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestThreadRefresh()
            }
        }
    }

    private func invalidateTimers() {
        desktopActivityTimer?.invalidate()
        desktopActivityTimer = nil
        threadListTimer?.invalidate()
        threadListTimer = nil
    }

    private func refreshDesktopActivity() async {
        let candidateSessionPaths = Dictionary(
            uniqueKeysWithValues: state.recentThreads.map { ($0.id, $0.sessionPath) }
        )
        let update = await desktopActivityService.load(candidateSessionPaths: candidateSessionPaths)

        if let runtimeSnapshot = update.runtimeSnapshot {
            state.apply(desktopSnapshot: runtimeSnapshot)
        } else if let runtimeErrorMessage = update.runtimeErrorMessage {
            state.recordDiagnostic("Desktop activity unavailable: \(runtimeErrorMessage)")
        }

        state.apply(desktopCompletionHints: update.latestTurnCompletedAtByThreadID)
        synchronizeThreadReadMarkers(from: update.latestViewedAtByThreadID)
        renderMenu()
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

        menu.addItem(.separator())
        menu.addItem(makeActionItem(title: "Refresh Threads", action: #selector(refreshThreadsAction)))

        let watchItem = makeActionItem(title: "Watch Latest Thread", action: #selector(watchLatestThreadAction))
        watchItem.isEnabled = !state.recentThreads.isEmpty
        menu.addItem(watchItem)

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
        case .waitingForUser:
            return waitingForUserIndicatorImage
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

        if thread.pendingRequestKind == .approval,
           let reason = thread.pendingRequestReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty {
            lines.append("Approval: \(reason)")
        }

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

    private func synchronizeThreadReadMarkers(from latestViewedAtByThreadID: [String: Date]) {
        guard !latestViewedAtByThreadID.isEmpty else { return }

        var didChange = false

        for thread in state.recentThreads {
            let viewedAt = latestViewedAtByThreadID[thread.id]
            if threadReadMarkers.markReadIfViewedAfterLastTerminalActivity(
                threadID: thread.id,
                lastTerminalActivityAt: thread.lastTerminalActivityAt,
                viewedAt: viewedAt
            ) {
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

    private func requestThreadRefresh() {
        guard threadRefreshTask == nil else {
            return
        }

        threadRefreshTask = Task { @MainActor in
            defer {
                threadRefreshTask = nil
            }

            do {
                try await refreshThreads()
            } catch {
                state.setConnection(.failed(message: error.localizedDescription))
                renderMenu()
            }
        }
    }

    private func requestDesktopActivityRefresh() {
        guard desktopActivityRefreshTask == nil else {
            return
        }

        desktopActivityRefreshTask = Task { @MainActor in
            defer {
                desktopActivityRefreshTask = nil
            }

            await refreshDesktopActivity()
        }
    }

    private func requestInitialSubscriptionWarmup() {
        Task { @MainActor [weak self] in
            await self?.warmInitialSubscriptions()
        }
    }

    private func fetchRecentThreads(limit: Int) async throws -> [CodexThread] {
        var threads: [CodexThread] = []
        var cursor: String?

        repeat {
            let response: ThreadListResponse = try await client.call(
                method: "thread/list",
                params: ThreadListParams(
                    cursor: cursor,
                    limit: ThreadListDisplay.fetchPageLimit,
                    sortKey: .updatedAt,
                    archived: false
                )
            )

            markConnectionHealthy()
            threads.append(contentsOf: response.data)
            cursor = response.nextCursor
        } while cursor != nil && threads.count < limit

        return Array(threads.prefix(limit))
    }

    private func reconcileLiveSubscriptions() async {
        let plan = ThreadSubscriptionPlanner.makePlan(
            recentThreads: state.recentThreads,
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

        let candidates = visibleThreadIDs.isEmpty ? state.recentThreads.map(\.id) : visibleThreadIDs
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
                state.markWatched(thread: thread)
            } else if let errorMessage = result.errorMessage {
                state.recordDiagnostic("Failed to resume thread \(result.threadID.prefix(8)): \(errorMessage)")
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
                    state.markUnwatched(threadIDs: Set([result.threadID]))
                }
            } else if let errorMessage = result.errorMessage {
                state.recordDiagnostic("Failed to unsubscribe thread \(result.threadID.prefix(8)): \(errorMessage)")
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

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu == self.menu else { return }

        requestDesktopActivityRefresh()
        requestThreadRefresh()
    }
}
