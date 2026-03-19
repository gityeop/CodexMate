import AppKit
import Combine
import KeyboardShortcuts
import UserNotifications

private struct ThreadMenuSection {
    let displayName: String
    let threadCount: Int
    let threads: [ThreadMenuThread]
}

private struct ThreadMenuThread {
    let thread: AppStateStore.ThreadRow
    let children: [ThreadMenuThread]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum RetentionPolicy {
        static let threadReadMarkerSeconds: TimeInterval = 30 * 24 * 60 * 60
        static let pendingDiscoveredThreadSeconds: TimeInterval = 2 * 60
        static let maxPendingDiscoveredThreads = 64
    }

    private enum ForegroundRefreshPolicy {
        static let minimumInterval: TimeInterval = 1
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
    private let preferences = AppPreferencesStore()
    private let strings = AppStrings.shared
    private let client = CodexAppServerClient()
    private let desktopActivityService = DesktopActivityService()
    private let desktopStateReader = CodexDesktopStateReader()
    private let projectCatalogReader = CodexDesktopProjectCatalogReader()
    private let launchAtLoginService = LaunchAtLoginService()
    private let updaterService = UpdaterService()
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
    private weak var highlightedMenuRowView: ThreadDropdownMenuRowView?
    private var expandedThreadIDs: Set<String> = []
    private var foregroundRefreshObserverTokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var foregroundRefreshThrottle = ForegroundRefreshThrottle(
        minimumInterval: ForegroundRefreshPolicy.minimumInterval
    )
    private var menuShortcutEventMonitor: Any?
    private lazy var settingsViewModel = SettingsViewModel(
        preferences: preferences,
        strings: strings,
        launchAtLoginService: launchAtLoginService,
        updaterService: updaterService
    )
    private lazy var settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)
    private lazy var menuToggleController = MenuToggleController(
        openMenu: { [weak self] in
            self?.openMenu()
        },
        closeMenu: { [weak self] in
            self?.closeMenu()
        }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        configureMainMenu()
        configureStatusItemButton()
        configurePreferencesObservers()
        configureGlobalShortcut()
        relativeDateFormatter.locale = preferences.locale

        configureClientCallbacks()
        configureForegroundRefreshObservers()
        requestNotificationPermission()
        renderMenu()

        Task {
            await connectAndLoad()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeForegroundRefreshObservers()
        invalidateTimers()

        Task {
            await client.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func configureStatusItemButton() {
        statusItem.menu = menu
        statusItem.button?.title = controller.overallStatus.icon
    }

    private func configureMainMenu() {
        NSApp.mainMenu = buildMainMenu()
    }

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(
            title: strings.text("menu.settings", language: preferences.language),
            action: #selector(openSettingsAction),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitTitle = "\(strings.text("menu.quit", language: preferences.language)) \(applicationDisplayName)"
        let quitItem = NSMenuItem(title: quitTitle, action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        return mainMenu
    }

    private var applicationDisplayName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return ProcessInfo.processInfo.processName
    }

    private func configurePreferencesObservers() {
        preferences.$language
            .sink { [weak self] _ in
                guard let self else { return }
                self.relativeDateFormatter.locale = self.preferences.locale
                NSApp.mainMenu = self.buildMainMenu()
                self.renderMenu()
            }
            .store(in: &cancellables)
    }

    private func configureGlobalShortcut() {
        KeyboardShortcuts.onKeyUp(for: .toggleMenuBarDropdown) { [weak self] in
            Task { @MainActor [weak self] in
                self?.menuToggleController.toggleMenu()
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
            controller.recordDiagnostic("User notifications are disabled outside an .app bundle.")
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func configureForegroundRefreshObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for name in names {
            let token = workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleForegroundRefreshNotification(name)
                }
            }
            foregroundRefreshObserverTokens.append(token)
        }
    }

    private func removeForegroundRefreshObservers() {
        guard !foregroundRefreshObserverTokens.isEmpty else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for token in foregroundRefreshObserverTokens {
            workspaceCenter.removeObserver(token)
        }
        foregroundRefreshObserverTokens.removeAll()
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

            do {
                try await loadInitialThreads()
            } catch {
                controller.recordDiagnostic("Initial thread load failed: \(error.localizedDescription)")
                renderMenu()
                scheduleRefreshTimerIfNeeded()
                requestDesktopActivityRefresh()
                requestThreadRefresh()
                requestInitialSubscriptionWarmup()
                return
            }

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
        guard let thread = controller.state.recentThreads.first else { return }

        await resumeThreadSubscriptions([thread.id])
        renderMenu()
    }

    private func handleClientTermination(reason: String?) {
        invalidateTimers()
        liveSubscribedThreadUpdatedAtByID.removeAll()
        controller.clearLiveRuntimeState()

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
                if preferences.completionNotificationsEnabled {
                    sendNotification(
                        title: strings.text("notification.turnCompleted.title", language: preferences.language),
                        body: controller.notificationBody(
                            forThreadID: notification.threadId,
                            fallback: strings.text("notification.turnCompleted.bodyFallback", language: preferences.language)
                        )
                    )
                }
            }
        case "error":
            decodeAndApply(payload, as: ErrorNotificationPayload.self) { [weak self] notification in
                guard let self else { return }
                controller.apply(notification: .error(notification))
                requestDesktopActivityRefresh()

                if !notification.willRetry && preferences.failureNotificationsEnabled {
                    sendNotification(
                        title: strings.text("notification.error.title", language: preferences.language),
                        body: controller.notificationBody(
                            forThreadID: notification.threadId,
                            fallback: notification.error.message.isEmpty
                                ? strings.text("notification.error.bodyFallback", language: preferences.language)
                                : notification.error.message
                        )
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
                if preferences.attentionNotificationsEnabled {
                    sendNotification(
                        title: strings.text("notification.needsInput.title", language: preferences.language),
                        body: controller.notificationBody(
                            forThreadID: request.threadId,
                            fallback: strings.text("notification.needsInput.bodyFallback", language: preferences.language)
                        )
                    )
                }
            }
        case "item/commandExecution/requestApproval", "commandExecution/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                controller.apply(serverRequest: .approval(request))
                controller.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                if preferences.attentionNotificationsEnabled {
                    sendNotification(
                        title: strings.text("notification.approval.title", language: preferences.language),
                        body: controller.notificationBody(
                            forThreadID: request.threadId,
                            fallback: strings.text("notification.approval.bodyFallback", language: preferences.language)
                        )
                    )
                }
            }
        case "item/fileChange/requestApproval", "fileChange/requestApproval":
            decodeAndApply(payload, as: ApprovalRequestPayload.self) { [weak self] request in
                guard let self else { return }
                controller.apply(serverRequest: .approval(request))
                controller.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
                if preferences.attentionNotificationsEnabled {
                    sendNotification(
                        title: strings.text("notification.approval.title", language: preferences.language),
                        body: controller.notificationBody(
                            forThreadID: request.threadId,
                            fallback: strings.text("notification.approval.bodyFallback", language: preferences.language)
                        )
                    )
                }
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

    private func handleForegroundRefreshNotification(_ name: Notification.Name, now: Date = Date()) {
        guard case .connected = controller.connection else {
            return
        }

        guard foregroundRefreshThrottle.shouldTrigger(now: now) else {
            return
        }

        controller.recordDiagnostic("foreground refresh via \(name.rawValue)")
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh(now: now)
        requestThreadRefresh(now: now)
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
            overallStatus: controller.overallStatus,
            hasRecentThreads: !controller.state.recentThreads.isEmpty
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
        highlightedMenuRowView = nil

        let preparedSnapshot = controller.prepareSnapshot(
            additionalTrackedThreadIDs: Set(liveSubscribedThreadUpdatedAtByID.keys)
        )
        let snapshot = preparedSnapshot.snapshot
        let menuSections = buildThreadMenuSections(
            snapshotSections: snapshot.projectSections,
            recentThreads: controller.state.recentThreads,
            projectCatalog: controller.projectCatalog
        )
        let renderThreadIDs = Set(flattenedThreadIDs(from: menuSections.flatMap(\.threads)))
        let renderedExpandableThreadIDs = collectExpandableThreadIDs(from: menuSections.flatMap(\.threads))
        expandedThreadIDs.formIntersection(renderedExpandableThreadIDs)
        let hasUnreadThreads = menuSections.flatMap(\.threads).contains(where: hasUnreadContent(in:))
        statusItem.button?.title = MenubarStatusPresentation.statusItemIcon(
            overallStatus: snapshot.overallStatus,
            hasUnreadThreads: hasUnreadThreads
        )
        var didChangeReadMarkers = preparedSnapshot.didChangeReadMarkers
        if controller.seedThreadReadMarkers(for: renderThreadIDs) {
            didChangeReadMarkers = true
        }
        if didChangeReadMarkers {
            persistThreadReadMarkers()
        }

        var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
        menu.removeAllItems()

        if menuSections.isEmpty {
            menu.addItem(makeStaticItem(title: strings.text("menu.noRecentThreads", language: preferences.language)))
        } else {
            for (index, section) in menuSections.enumerated() {
                if index > 0 {
                    menu.addItem(.separator())
                }

                let item = makeStaticItem(title: projectSectionTitle(for: section))
                menu.addItem(item)

                for thread in section.threads {
                    addThreadMenuItems(
                        thread,
                        level: 0,
                        worktreeDisplayName: section.displayName,
                        hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID
                    )
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
        menu.addItem(
            makeActionItem(
                title: strings.text("menu.refreshThreads", language: preferences.language),
                action: #selector(refreshThreadsAction)
            )
        )

        let watchItem = makeActionItem(
            title: strings.text("menu.watchLatestThread", language: preferences.language),
            action: #selector(watchLatestThreadAction)
        )
        watchItem.isEnabled = !controller.state.recentThreads.isEmpty
        menu.addItem(watchItem)

        menu.addItem(.separator())
        let settingsItem = makeActionItem(
            title: strings.text("menu.settings", language: preferences.language),
            action: #selector(openSettingsAction)
        )
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(
            makeActionItem(
                title: strings.text("menu.quit", language: preferences.language),
                action: #selector(quit)
            )
        )
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

    private func buildThreadMenuSections(
        snapshotSections: [MenubarProjectSectionSnapshot],
        recentThreads: [AppStateStore.ThreadRow],
        projectCatalog: CodexDesktopProjectCatalog
    ) -> [ThreadMenuSection] {
        guard !recentThreads.isEmpty else {
            return []
        }

        let threadByID = Dictionary(uniqueKeysWithValues: recentThreads.map { ($0.id, $0) })
        let parentIDByThreadID: [String: String] = Dictionary(uniqueKeysWithValues: recentThreads.compactMap { thread in
            guard let parentID = thread.parentThreadID else {
                return nil
            }

            return (thread.id, parentID)
        })

        if snapshotSections.isEmpty {
            let sectionsByProjectID = Dictionary(grouping: recentThreads) { thread in
                projectCatalog.project(for: thread.cwd).id
            }

            return sectionsByProjectID.keys.sorted().compactMap { projectID -> ThreadMenuSection? in
                guard let sectionThreads = sectionsByProjectID[projectID], !sectionThreads.isEmpty else {
                    return nil
                }

                let displayName = projectCatalog.project(for: sectionThreads[0].cwd).displayName
                let rootThreads = sectionRootThreads(
                    allThreads: sectionThreads,
                    visibleRootIDs: nil,
                    parentIDByThreadID: parentIDByThreadID
                )
                let rootNodes = rootThreads.compactMap { thread in
                    buildThreadMenuThread(
                        thread: thread,
                        threadByID: threadByID,
                        parentIDByThreadID: parentIDByThreadID,
                        visited: []
                    )
                }

                return ThreadMenuSection(
                    displayName: displayName,
                    threadCount: flattenedThreadIDs(from: rootNodes).count,
                    threads: rootNodes.sorted(by: Self.isNewerMenuThread)
                )
            }
        }

        return snapshotSections.compactMap { snapshotSection -> ThreadMenuSection? in
            let sectionThreads = recentThreads.filter {
                projectCatalog.project(for: $0.cwd).id == snapshotSection.section.id
            }

            guard !sectionThreads.isEmpty else {
                return nil
            }

            let rootThreads = sectionRootThreads(
                allThreads: sectionThreads,
                visibleRootIDs: Set(snapshotSection.threads.map { $0.id }),
                parentIDByThreadID: parentIDByThreadID
            )
            let rootNodes = rootThreads.compactMap { thread in
                buildThreadMenuThread(
                    thread: thread,
                    threadByID: threadByID,
                    parentIDByThreadID: parentIDByThreadID,
                    visited: []
                )
            }

            return ThreadMenuSection(
                displayName: snapshotSection.section.displayName,
                threadCount: flattenedThreadIDs(from: rootNodes).count,
                threads: rootNodes.sorted(by: Self.isNewerMenuThread)
            )
        }
    }

    private func sectionRootThreads(
        allThreads: [AppStateStore.ThreadRow],
        visibleRootIDs: Set<String>?,
        parentIDByThreadID: [String: String]
    ) -> [AppStateStore.ThreadRow] {
        let threadByID = Dictionary(uniqueKeysWithValues: allThreads.map { ($0.id, $0) })

        if let visibleRootIDs, !visibleRootIDs.isEmpty {
            var roots = allThreads.filter { visibleRootIDs.contains($0.id) }
            let orphanThreads = allThreads.filter { thread in
                thread.isSubagent && !threadHasAncestor(
                    thread.id,
                    in: visibleRootIDs,
                    parentIDByThreadID: parentIDByThreadID
                )
            }
            roots.append(contentsOf: orphanThreads.filter { !visibleRootIDs.contains($0.id) })
            return roots.sorted(by: Self.isNewerThread)
        }

        return allThreads.filter { thread in
            guard let parentID = parentIDByThreadID[thread.id] else {
                return true
            }

            return threadByID[parentID] == nil
        }
        .sorted(by: Self.isNewerThread)
    }

    private func buildThreadMenuThread(
        thread: AppStateStore.ThreadRow,
        threadByID: [String: AppStateStore.ThreadRow],
        parentIDByThreadID: [String: String],
        visited: Set<String>
    ) -> ThreadMenuThread? {
        guard !visited.contains(thread.id) else {
            return nil
        }

        let childIDs = parentIDByThreadID
            .filter { $0.value == thread.id }
            .map(\.key)
            .sorted { lhs, rhs in
                guard let lhsThread = threadByID[lhs], let rhsThread = threadByID[rhs] else {
                    return lhs < rhs
                }

                return Self.isNewerThread(lhsThread, rhsThread)
            }

        let nextVisited = visited.union([thread.id])
        let children: [ThreadMenuThread] = childIDs.compactMap { childID in
            guard let childThread = threadByID[childID] else {
                return nil
            }

            return buildThreadMenuThread(
                thread: childThread,
                threadByID: threadByID,
                parentIDByThreadID: parentIDByThreadID,
                visited: nextVisited
            )
        }

        return ThreadMenuThread(thread: thread, children: children)
    }

    private func threadHasAncestor(
        _ threadID: String,
        in ancestorIDs: Set<String>,
        parentIDByThreadID: [String: String]
    ) -> Bool {
        var currentThreadID = parentIDByThreadID[threadID]
        var visited: Set<String> = [threadID]

        while let parentThreadID = currentThreadID {
            if !visited.insert(parentThreadID).inserted {
                return false
            }

            if ancestorIDs.contains(parentThreadID) {
                return true
            }

            currentThreadID = parentIDByThreadID[parentThreadID]
        }

        return false
    }

    private func flattenedThreadIDs(from threads: [ThreadMenuThread]) -> [String] {
        threads.flatMap { thread in
            [thread.thread.id] + flattenedThreadIDs(from: thread.children)
        }
    }

    private func collectExpandableThreadIDs(from threads: [ThreadMenuThread]) -> Set<String> {
        var threadIDs: Set<String> = []

        for thread in threads {
            if !thread.children.isEmpty {
                threadIDs.insert(thread.thread.id)
                threadIDs.formUnion(collectExpandableThreadIDs(from: thread.children))
            }
        }

        return threadIDs
    }

    private func hasUnreadContent(in thread: ThreadMenuThread) -> Bool {
        if controller.threadReadMarkers.hasUnreadContent(
            threadID: thread.thread.id,
            lastTerminalActivityAt: thread.thread.lastTerminalActivityAt
        ) {
            return true
        }

        return thread.children.contains(where: hasUnreadContent(in:))
    }

    private func addThreadMenuItems(
        _ thread: ThreadMenuThread,
        level: Int,
        worktreeDisplayName: String,
        hoverTooltipContentsByThreadID: inout [String: MenubarStatusPresentation.ThreadTooltipContent]
    ) {
        let hasUnreadContent = controller.threadReadMarkers.hasUnreadContent(
            threadID: thread.thread.id,
            lastTerminalActivityAt: thread.thread.lastTerminalActivityAt
        )
        let threadSnapshot = MenubarThreadSnapshot(thread: thread.thread, hasUnreadContent: hasUnreadContent)
        let tooltipContent = MenubarStatusPresentation.threadTooltipContent(
            worktreeDisplayName: worktreeDisplayName,
            thread: thread.thread,
            strings: strings,
            language: preferences.language
        )

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = thread.thread.id
        item.toolTip = nil

        let view = ThreadDropdownMenuRowView(frame: .zero)
        view.configure(
            title: menuTitle(for: thread.thread),
            indicatorImage: indicatorImage(for: threadSnapshot),
            indentationLevel: level,
            isExpandable: !thread.children.isEmpty,
            isExpanded: expandedThreadIDs.contains(thread.thread.id),
            onOpen: { [weak self] in
                self?.openThread(threadID: thread.thread.id)
            },
            onToggle: thread.children.isEmpty ? nil : { [weak self] in
                self?.toggleThreadExpansion(thread.thread.id)
            }
        )
        if highlightedThreadID == thread.thread.id {
            view.isHighlighted = true
            highlightedMenuRowView = view
        }
        view.frame = NSRect(origin: .zero, size: view.intrinsicContentSize)
        item.view = view
        hoverTooltipContentsByThreadID[thread.thread.id] = tooltipContent
        menu.addItem(item)

        guard expandedThreadIDs.contains(thread.thread.id) else {
            return
        }

        for child in thread.children {
            addThreadMenuItems(
                child,
                level: level + 1,
                worktreeDisplayName: worktreeDisplayName,
                hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID
            )
        }
    }

    private static func isNewerThread(_ lhs: AppStateStore.ThreadRow, _ rhs: AppStateStore.ThreadRow) -> Bool {
        if lhs.activityUpdatedAt == rhs.activityUpdatedAt {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        return lhs.activityUpdatedAt > rhs.activityUpdatedAt
    }

    private static func isNewerMenuThread(_ lhs: ThreadMenuThread, _ rhs: ThreadMenuThread) -> Bool {
        isNewerThread(lhs.thread, rhs.thread)
    }

    private func menuTitle(for thread: AppStateStore.ThreadRow) -> String {
        let relativeDate = relativeDateFormatter.localizedString(for: thread.activityUpdatedAt, relativeTo: Date())
        return MenubarStatusPresentation.threadTitle(
            for: thread,
            relativeDate: relativeDate,
            maxDisplayTitleLength: ThreadListDisplay.maxThreadDisplayTitleLength
        )
    }

    private func projectSectionTitle(for section: ThreadMenuSection) -> String {
        MenubarStatusPresentation.projectSectionTitle(
            displayName: section.displayName,
            threadCount: section.threadCount,
            maxDisplayNameLength: ThreadListDisplay.maxProjectDisplayNameLength,
            strings: strings,
            language: preferences.language
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

    private func updateHoverTooltip(for item: NSMenuItem?) {
        let hoveredMenuRowView = item?.view as? ThreadDropdownMenuRowView
        if highlightedMenuRowView !== hoveredMenuRowView {
            highlightedMenuRowView?.isHighlighted = false
            highlightedMenuRowView = hoveredMenuRowView
        }
        highlightedMenuRowView?.isHighlighted = item != nil

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
        highlightedMenuRowView?.isHighlighted = false
        highlightedMenuRowView = nil
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
        let line = "[CodexMate] \(message)\n"
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
                controller.recordDiagnostic("Thread refresh failed: \(error.localizedDescription)")
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
            recentThreads: controller.state.recentThreads,
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
        let candidates = controller.state.recentThreads.map(\.id)
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

    private func openMenu() {
        statusItem.button?.performClick(nil)
    }

    private func closeMenu() {
        menu.cancelTracking()
    }

    private func installMenuShortcutEventMonitor() {
        guard menuShortcutEventMonitor == nil else {
            return
        }

        menuShortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard
                let self,
                let shortcut = KeyboardShortcuts.Shortcut(name: .toggleMenuBarDropdown),
                KeyboardShortcuts.Shortcut(event: event) == shortcut
            else {
                return event
            }

            self.menuToggleController.toggleMenu()
            return nil
        }
    }

    private func removeMenuShortcutEventMonitor() {
        guard let menuShortcutEventMonitor else {
            return
        }

        NSEvent.removeMonitor(menuShortcutEventMonitor)
        self.menuShortcutEventMonitor = nil
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
    private func openSettingsAction() {
        launchAtLoginService.refresh()
        updaterService.refresh()
        settingsWindowController.showWindow(nil)
    }

    @objc
    private func openThread(_ sender: NSMenuItem) {
        guard let threadID = sender.representedObject as? String else { return }
        openThread(threadID: threadID)
    }

    private func openThread(threadID: String) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            copyThreadID(threadID)
            return
        }

        closeMenu()

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

    private func toggleThreadExpansion(_ threadID: String) {
        if expandedThreadIDs.contains(threadID) {
            expandedThreadIDs.remove(threadID)
        } else {
            expandedThreadIDs.insert(threadID)
        }

        renderMenu()
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
        KeyboardShortcuts.disable(.toggleMenuBarDropdown)
        installMenuShortcutEventMonitor()
        menuToggleController.menuWillOpen()
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
        removeMenuShortcutEventMonitor()
        KeyboardShortcuts.enable(.toggleMenuBarDropdown)
        menuToggleController.menuDidClose()
        scheduleRefreshTimerIfNeeded()
    }
}
