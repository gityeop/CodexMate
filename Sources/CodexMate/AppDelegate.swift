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

    private enum StatusAnimation {
        static let frameInterval: TimeInterval = 0.12
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

    private var statusItem: NSStatusItem?
    private let menu = ThreadMenu()
    private let notchStatusOverlay = NotchStatusOverlayController()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let preferences = AppPreferencesStore()
    private let strings = AppStrings.shared
    private let client = CodexAppServerClient()
    private let desktopActivityService = DesktopActivityService()
    private let desktopStateReader = CodexDesktopStateReader()
    private let projectCatalogReader = CodexDesktopProjectCatalogReader()
    private let launchAtLoginService = LaunchAtLoginService()
    private let updaterService = UpdaterService()
    private let statusSpriteCatalog = MenubarStatusSpriteCatalog()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForUserIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")
    private let hoverTooltipController = ThreadHoverTooltipController()
    private lazy var appServerRecentThreadListing = AppServerRecentThreadListing(
        client: client,
        fetchPageLimit: ThreadListDisplay.fetchPageLimit
    )
    private lazy var recentThreadListing = FallbackRecentThreadListing(
        primary: appServerRecentThreadListing,
        fallback: desktopStateReader
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
    private var statusAnimationTimer: Timer?
    private var currentStatusSprite: MenubarStatusPresentation.StatusSprite = .connecting
    private var currentStatusDisplayName = AppStateStore.OverallStatus.connecting.displayName
    private var currentStatusFallbackIcon = AppStateStore.OverallStatus.connecting.icon
    private var statusAnimationFrameIndex = 0
    private var currentEffectiveDisplayMode: AppDisplayMode?
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
    private var projectShortcutThreadIDs: [String] = []
    private var foregroundRefreshObserverTokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var foregroundRefreshThrottle = ForegroundRefreshThrottle(
        minimumInterval: ForegroundRefreshPolicy.minimumInterval
    )
    private var menuShortcutEventMonitor: Any?
    private var menuDismissLocalEventMonitor: Any?
    private var menuDismissGlobalEventMonitor: Any?
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
        debugLog("applicationDidFinishLaunching log=\(DebugTraceLogger.logFileURL.path)")
        menu.autoenablesItems = false
        menu.delegate = self
        menu.onKeyboardShortcut = { [weak self] action in
            self?.handleMenuKeyboardShortcut(action) ?? false
        }
        configureMainMenu()
        configureNotchStatusPanel()
        configurePreferencesObservers()
        configureGlobalShortcut()
        relativeDateFormatter.locale = preferences.locale
        applyPresentationMode(force: true)

        configureClientCallbacks()
        configureForegroundRefreshObservers()
        requestNotificationPermission()
        renderMenu()

        Task {
            await connectAndLoad()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("applicationWillTerminate event=\(debugEventSummary(NSApp.currentEvent))")
        removeForegroundRefreshObservers()
        invalidateTimers()
        invalidateStatusAnimationTimer()
        removeMenuShortcutEventMonitor()
        removeMenuDismissEventMonitors()
        notchStatusOverlay.hide()

        Task {
            await client.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        debugLog("applicationShouldTerminate event=\(debugEventSummary(NSApp.currentEvent))")
        return .terminateNow
    }

    private func applyPresentationMode(force: Bool = false) {
        let nextMode = preferences.displayMode.resolved(hasHardwareNotch: preferredNotchScreen() != nil)
        let previousMode = currentEffectiveDisplayMode

        debugLog(
            "applyPresentationMode force=\(force) requested=\(preferences.displayMode.rawValue) previous=\(previousMode?.rawValue ?? "nil") next=\(nextMode.rawValue)"
        )

        if !force, previousMode == nextMode {
            if nextMode == .notch {
                updateNotchStatusPanel()
            } else {
                notchStatusOverlay.hide()
            }
            applyStatusPresentation()
            return
        }

        if isMenuOpen {
            closeMenu()
        }

        tearDownPresentation(for: previousMode)
        currentEffectiveDisplayMode = nextMode
        setUpPresentation(for: nextMode)
        applyStatusPresentation()
    }

    private func tearDownPresentation(for displayMode: AppDisplayMode?) {
        switch displayMode {
        case .menuBar:
            removeStatusItem()
        case .notch:
            invalidateStatusAnimationTimer()
            notchStatusOverlay.hideMenu()
            notchStatusOverlay.hide()
            removeMenuDismissEventMonitors()
        case nil:
            break
        }
    }

    private func setUpPresentation(for displayMode: AppDisplayMode) {
        switch displayMode {
        case .menuBar:
            configureStatusItemForMenuBarMode()
            invalidateStatusAnimationTimer()
            notchStatusOverlay.hide()
        case .notch:
            removeStatusItem()
            scheduleStatusAnimationTimerIfNeeded()
            updateNotchStatusPanel()
        }
    }

    @discardableResult
    private func ensureStatusItem() -> NSStatusItem {
        if let statusItem {
            return statusItem
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        return statusItem
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        statusItem.menu = nil
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.button?.image = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func configureStatusItemForMenuBarMode() {
        let statusItem = ensureStatusItem()
        statusItem.menu = menu
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.toolTip = currentStatusDisplayName
    }

    private func configureNotchStatusPanel() {
        notchStatusOverlay.onActivate = { [weak self] in
            self?.menuToggleController.toggleMenu()
        }
        notchStatusOverlay.onKeyDown = { [weak self] event in
            self?.handleOverlayShortcutEvent(event) ?? false
        }
        updateNotchStatusPanel()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc
    private func handleScreenParametersChanged() {
        applyPresentationMode()
    }

    private func updateNotchStatusPanel() {
        guard currentEffectiveDisplayMode == .notch else {
            notchStatusOverlay.hide()
            return
        }

        guard let screen = preferredNotchScreen() else {
            notchStatusOverlay.hide()
            return
        }

        if notchStatusOverlay.isMenuExpanded {
            notchStatusOverlay.showMenu(on: screen)
        } else {
            notchStatusOverlay.show(on: screen)
        }
    }

    private func preferredNotchScreen() -> NSScreen? {
        NSScreen.screens.first(where: \.hasCameraHousing)
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

        preferences.$threadsPerProjectLimit
            .dropFirst()
            .sink { [weak self] _ in
                self?.renderMenu()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appDisplayModeDidChange, object: preferences)
            .sink { [weak self] _ in
                guard let self else { return }
                self.debugLog(
                    "displayModeChanged requested=\(self.preferences.displayMode.rawValue) effective=\(self.preferences.displayMode.resolved(hasHardwareNotch: self.preferredNotchScreen() != nil).rawValue)"
                )
                self.applyPresentationMode()
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
        guard let thread = controller.recentThreads.first else { return }

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

    private func scheduleStatusAnimationTimerIfNeeded() {
        guard currentEffectiveDisplayMode == .notch else {
            return
        }

        guard statusAnimationTimer == nil else {
            return
        }

        let timer = Timer(
            timeInterval: StatusAnimation.frameInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleStatusAnimationTick()
            }
        }
        statusAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshSchedulingPolicy() -> RefreshSchedulingPolicy {
        RefreshSchedulingPolicy.current(
            isMenuOpen: isMenuOpen,
            overallStatus: controller.overallStatus,
            hasRecentThreads: !controller.recentThreads.isEmpty
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

    private func invalidateStatusAnimationTimer() {
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
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

    private func handleStatusAnimationTick() {
        let frameCount = statusSpriteCatalog.frameCount(for: currentStatusSprite)
        guard frameCount > 1 else {
            return
        }

        statusAnimationFrameIndex = (statusAnimationFrameIndex + 1) % frameCount
        applyStatusPresentation()
    }

    private func renderStatusItem(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) {
        let sprite = MenubarStatusPresentation.statusItemSprite(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads
        )
        if sprite != currentStatusSprite {
            currentStatusSprite = sprite
            statusAnimationFrameIndex = 0
        }

        currentStatusDisplayName = MenubarStatusPresentation.statusDisplayName(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads,
            strings: strings,
            language: preferences.language
        )
        currentStatusFallbackIcon = MenubarStatusPresentation.statusItemIcon(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads
        )
        applyStatusPresentation()
    }

    private func applyStatusPresentation() {
        switch currentEffectiveDisplayMode {
        case .menuBar:
            applyMenuBarStatusItem()
        case .notch:
            applyNotchStatusOverlay()
        case nil:
            break
        }
    }

    private func applyMenuBarStatusItem() {
        let statusItem = ensureStatusItem()
        statusItem.menu = menu
        guard let button = statusItem.button else {
            return
        }

        button.image = nil
        button.title = currentStatusFallbackIcon
        button.imagePosition = .noImage
        button.toolTip = currentStatusDisplayName
    }

    private func applyNotchStatusOverlay() {
        guard let overlayScreen = preferredNotchScreen() else {
            notchStatusOverlay.hide()
            return
        }

        notchStatusOverlay.update(
            spriteImage: statusSpriteCatalog.notchFrame(
                for: currentStatusSprite,
                index: statusAnimationFrameIndex,
                renderedPixelSize: 128,
                renderedPointSize: NotchStatusOverlayController.Metrics.spritePointSize
            ),
            statusSprite: currentStatusSprite,
            statusText: currentStatusDisplayName,
            frameIndex: statusAnimationFrameIndex,
            hasNotch: overlayScreen.hasCameraHousing
        )
        if !notchStatusOverlay.isVisible {
            notchStatusOverlay.show(on: overlayScreen)
        }
    }

    private func renderMenu() {
        hoverTooltipWorkItem?.cancel()
        hoverTooltipWorkItem = nil

        let preparedSnapshot = controller.prepareSnapshot(
            additionalTrackedThreadIDs: Set(liveSubscribedThreadUpdatedAtByID.keys),
            visibleThreadLimit: preferences.threadsPerProjectLimit
        )
        let snapshot = preparedSnapshot.snapshot
        let menuSections = buildThreadMenuSections(
            snapshotSections: snapshot.projectSections,
            recentThreads: controller.recentThreads,
            projectCatalog: controller.projectCatalog
        )
        projectShortcutThreadIDs = menuSections.compactMap { $0.threads.first?.thread.id }
        let renderThreadIDs = Set(flattenedThreadIDs(from: menuSections.flatMap(\.threads)))
        let hasUnreadThreads = menuSections.flatMap(\.threads).contains(where: hasUnreadContent(in:))
        renderStatusItem(overallStatus: snapshot.overallStatus, hasUnreadThreads: hasUnreadThreads)
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

                for (threadIndex, thread) in section.threads.enumerated() {
                    addThreadMenuItems(
                        thread,
                        level: 0,
                        worktreeDisplayName: section.displayName,
                        hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID,
                        keyEquivalent: index < 5 && threadIndex == 0 ? String(index + 1) : nil
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
        watchItem.isEnabled = !controller.recentThreads.isEmpty
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
        if currentEffectiveDisplayMode == .notch {
            notchStatusOverlay.setMenuItems(overlayMenuEntries(from: menu.items))
        }
        scheduleRefreshTimerIfNeeded()
    }

    private func overlayMenuEntries(from menuItems: [NSMenuItem]) -> [NotchStatusOverlayMenuEntry] {
        menuItems.compactMap(overlayMenuEntry(for:))
    }

    private func overlayMenuEntry(for item: NSMenuItem) -> NotchStatusOverlayMenuEntry? {
        if item.isSeparatorItem {
            return .separator()
        }

        if !item.isEnabled && item.action == nil {
            return .header(item.title)
        }

        let splitTitle = splitOverlayMenuTitle(item.title)
        let action = item.action
        let target = item.target
        let indicatorImage = item.image
        let indentationLevel = item.indentationLevel
        let isEnabled = item.isEnabled
        let representedThreadID = item.representedObject as? String

        let onSelect: (() -> Void)? = { [weak self] in
            guard let self else { return }
            guard let action else { return }

            self.debugLog(
                "overlay entry selection title=\(item.title) action=\(NSStringFromSelector(action)) represented=\(String(describing: item.representedObject)) event=\(self.debugEventSummary(NSApp.currentEvent))"
            )

            switch action {
            case #selector(openThread(_:)):
                guard let representedThreadID else { return }
                self.debugLog("overlay entry openThread thread=\(representedThreadID)")
                self.openThread(threadID: representedThreadID)
            case #selector(refreshThreadsAction):
                self.debugLog("overlay entry refreshThreads")
                self.closeMenu()
                self.refreshThreadsAction()
            case #selector(watchLatestThreadAction):
                self.debugLog("overlay entry watchLatestThread")
                self.closeMenu()
                self.watchLatestThreadAction()
            case #selector(openSettingsAction):
                self.debugLog("overlay entry openSettings")
                self.closeMenu()
                self.openSettingsAction()
            case #selector(quit):
                self.debugLog("overlay entry quit")
                self.quit()
            default:
                self.debugLog("overlay entry fallback action=\(NSStringFromSelector(action))")
                self.closeMenu()
                _ = NSApp.sendAction(action, to: target, from: nil)
            }
        }

        return .item(
            primaryText: splitTitle.primary,
            secondaryText: splitTitle.secondary,
            identifier: representedThreadID,
            indicatorImage: indicatorImage,
            indentationLevel: indentationLevel,
            isEnabled: isEnabled,
            onSelect: onSelect
        )
    }

    private func splitOverlayMenuTitle(_ title: String) -> (primary: String, secondary: String?) {
        guard let separatorRange = title.range(of: " | ", options: .backwards) else {
            return (title, nil)
        }

        let primary = String(title[..<separatorRange.lowerBound])
        let secondary = String(title[separatorRange.upperBound...])
        return (primary, secondary.isEmpty ? nil : secondary)
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
        hoverTooltipContentsByThreadID: inout [String: MenubarStatusPresentation.ThreadTooltipContent],
        keyEquivalent: String? = nil
    ) {
        let hasUnreadContent = controller.threadReadMarkers.hasUnreadContent(
            threadID: thread.thread.id,
            lastTerminalActivityAt: thread.thread.lastTerminalActivityAt
        )
        let threadSnapshot = MenubarThreadSnapshot(thread: thread.thread, hasUnreadContent: hasUnreadContent)
        let title = menuTitle(for: thread.thread)
        let tooltipContent = MenubarStatusPresentation.threadTooltipContent(
            worktreeDisplayName: worktreeDisplayName,
            thread: thread.thread,
            strings: strings,
            language: preferences.language
        )

        let item = NSMenuItem(title: title, action: #selector(openThread(_:)), keyEquivalent: keyEquivalent ?? "")
        item.target = self
        item.representedObject = thread.thread.id
        item.toolTip = nil
        item.indentationLevel = level
        item.image = indicatorImage(for: threadSnapshot)
        if keyEquivalent != nil {
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags.command
        }
        hoverTooltipContentsByThreadID[thread.thread.id] = tooltipContent
        menu.addItem(item)

        for child in thread.children {
            addThreadMenuItems(
                child,
                level: level + 1,
                worktreeDisplayName: worktreeDisplayName,
                hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID,
                keyEquivalent: nil
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
        let line = "[CodexMate] \(message)\n"
        if let data = line.data(using: .utf8) {
            try? FileHandle.standardError.write(contentsOf: data)
        }
        DebugTraceLogger.log(message)
        controller.recordDiagnostic(message)
    }

    private func debugScreenPoint(_ point: NSPoint) -> String {
        "\(Int(point.x)),\(Int(point.y))"
    }

    private func debugEventSummary(_ event: NSEvent?) -> String {
        guard let event else {
            return "nil"
        }

        let point = event.window.map {
            debugScreenPoint($0.convertToScreen(CGRect(origin: event.locationInWindow, size: .zero)).origin)
        } ?? debugScreenPoint(event.locationInWindow)
        return "type=\(event.type) point=\(point) window=\(event.window?.windowNumber ?? 0) modifiers=\(event.modifierFlags.rawValue)"
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
        let candidates = controller.recentThreads.map(\.id)
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
        switch currentEffectiveDisplayMode {
        case .menuBar:
            debugLog("openMenu mode=menuBar")
            hideHoverTooltip()
            renderMenu()
            requestDesktopActivityRefresh()
            requestThreadRefresh()
            configureStatusItemForMenuBarMode()
            statusItem?.button?.performClick(nil)
        case .notch:
            guard let screen = preferredNotchScreen() else {
                applyPresentationMode()
                return
            }

            debugLog("openMenu mode=notch screen=\(screen.localizedName)")
            hideHoverTooltip()
            renderMenu()
            isMenuOpen = true
            KeyboardShortcuts.disable(.toggleMenuBarDropdown)
            installMenuShortcutEventMonitor()
            installMenuDismissEventMonitors()
            menuToggleController.menuWillOpen()
            scheduleRefreshTimerIfNeeded()
            requestDesktopActivityRefresh()
            requestThreadRefresh()
            notchStatusOverlay.showMenu(on: screen)
        case nil:
            applyPresentationMode(force: true)
            openMenu()
        }
    }

    private func closeMenu() {
        debugLog("closeMenu event=\(debugEventSummary(NSApp.currentEvent))")
        switch currentEffectiveDisplayMode {
        case .menuBar:
            menu.cancelTracking()
        case .notch:
            hideHoverTooltip()
            isMenuOpen = false
            removeMenuDismissEventMonitors()
            removeMenuShortcutEventMonitor()
            KeyboardShortcuts.enable(.toggleMenuBarDropdown)
            menuToggleController.menuDidClose()
            notchStatusOverlay.hideMenu()
            scheduleRefreshTimerIfNeeded()
        case nil:
            break
        }
    }

    private func installMenuShortcutEventMonitor() {
        guard menuShortcutEventMonitor == nil else {
            return
        }

        menuShortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleOverlayShortcutEvent(event) ? nil : event
        }
    }

    private func removeMenuShortcutEventMonitor() {
        guard let menuShortcutEventMonitor else {
            return
        }

        NSEvent.removeMonitor(menuShortcutEventMonitor)
        self.menuShortcutEventMonitor = nil
    }

    private func handleMenuKeyboardShortcut(_ action: ThreadMenuKeyboardShortcutAction) -> Bool {
        switch action {
        case .openHighlightedThread:
            let threadID = highlightedThreadID ?? (menu.highlightedItem?.representedObject as? String)
            guard let threadID else {
                return false
            }

            openThread(threadID: threadID)
            return true
        case let .openProjectThread(index):
            guard projectShortcutThreadIDs.indices.contains(index) else {
                return false
            }

            let threadID = projectShortcutThreadIDs[index]
            notchStatusOverlay.flashMenuItem(identifier: threadID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.openThread(threadID: threadID)
            }
            return true
        }
    }

    private func handleOverlayShortcutEvent(_ event: NSEvent) -> Bool {
        if let shortcut = KeyboardShortcuts.Shortcut(name: .toggleMenuBarDropdown),
           KeyboardShortcuts.Shortcut(event: event) == shortcut {
            debugLog("overlay shortcut toggle event=\(debugEventSummary(event))")
            menuToggleController.toggleMenu()
            return true
        }

        guard isMenuOpen else {
            return false
        }

        if event.keyCode == 53 {
            debugLog("overlay shortcut escape")
            closeMenu()
            return true
        }

        guard let action = ThreadMenu.shortcutAction(for: event) else {
            return false
        }

        debugLog("overlay shortcut action=\(action)")
        return handleMenuKeyboardShortcut(action)
    }

    private func installMenuDismissEventMonitors() {
        guard menuDismissLocalEventMonitor == nil, menuDismissGlobalEventMonitor == nil else {
            return
        }

        menuDismissLocalEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.dismissExpandedMenuIfNeeded(screenPoint: NSEvent.mouseLocation)
            return event
        }

        menuDismissGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismissExpandedMenuIfNeeded(screenPoint: NSEvent.mouseLocation)
        }
    }

    private func removeMenuDismissEventMonitors() {
        if let menuDismissLocalEventMonitor {
            NSEvent.removeMonitor(menuDismissLocalEventMonitor)
            self.menuDismissLocalEventMonitor = nil
        }

        if let menuDismissGlobalEventMonitor {
            NSEvent.removeMonitor(menuDismissGlobalEventMonitor)
            self.menuDismissGlobalEventMonitor = nil
        }
    }

    private func dismissExpandedMenuIfNeeded(screenPoint: NSPoint) {
        guard isMenuOpen else {
            return
        }

        if notchStatusOverlay.containsExpandedMenu(screenPoint: screenPoint) {
            debugLog("dismissExpandedMenuIfNeeded insideOverlay point=\(debugScreenPoint(screenPoint))")
            return
        }

        if let buttonFrame = statusItemButtonFrame(), buttonFrame.contains(screenPoint) {
            debugLog("dismissExpandedMenuIfNeeded insideStatusButton point=\(debugScreenPoint(screenPoint))")
            return
        }

        debugLog("dismissExpandedMenuIfNeeded closing point=\(debugScreenPoint(screenPoint))")
        closeMenu()
    }

    private func statusItemButtonFrame() -> CGRect? {
        guard let button = statusItem?.button,
              let window = button.window else {
            return nil
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(buttonFrameInWindow)
    }

    @objc
    private func toggleStatusPanelAction() {
        debugLog("toggleStatusPanelAction event=\(debugEventSummary(NSApp.currentEvent))")
        menuToggleController.toggleMenu()
    }

    @objc
    private func refreshThreadsAction() {
        debugLog("refreshThreadsAction")
        requestDesktopActivityRefresh()
        requestThreadRefresh()
    }

    @objc
    private func watchLatestThreadAction() {
        debugLog("watchLatestThreadAction")
        Task {
            await watchLatestThread()
        }
    }

    @objc
    private func openSettingsAction() {
        debugLog("openSettingsAction")
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
        debugLog("openThread thread=\(threadID) event=\(debugEventSummary(NSApp.currentEvent))")
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            debugLog("openThread copyingThreadID thread=\(threadID)")
            copyThreadID(threadID)
            return
        }

        closeMenu()

        guard let deepLinkURL = CodexDeepLink.threadURL(threadID: threadID) else {
            debugLog("openThread failedToBuildDeeplink thread=\(threadID)")
            controller.recordDiagnostic("Unable to build a Codex deeplink for thread \(threadID).")
            renderMenu()
            return
        }

        if NSWorkspace.shared.open(deepLinkURL) {
            debugLog("openThread openedViaWorkspace thread=\(threadID)")
            markThreadRead(threadID)
            renderMenu()
            return
        }

        guard let appURL = CodexApplicationLocator.locate() else {
            debugLog("openThread missingAppURL thread=\(threadID)")
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
            debugLog("openThread launchedViaOpenCommand thread=\(threadID)")
            markThreadRead(threadID)
            renderMenu()
        } catch {
            debugLog("openThread openCommandFailed thread=\(threadID) error=\(error.localizedDescription)")
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
        debugLog("quit invoked event=\(debugEventSummary(NSApp.currentEvent))")
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        guard menu == self.menu,
              let shortcutAction = ThreadMenu.shortcutAction(for: event) else {
            return false
        }

        return handleMenuKeyboardShortcut(shortcutAction)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == self.menu else { return }

        debugLog("menuWillOpen")
        hideHoverTooltip()
        isMenuOpen = true
        renderMenu()
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

        debugLog("menuDidClose")
        hideHoverTooltip()
        isMenuOpen = false
        removeMenuShortcutEventMonitor()
        KeyboardShortcuts.enable(.toggleMenuBarDropdown)
        menuToggleController.menuDidClose()
        scheduleRefreshTimerIfNeeded()
    }
}
