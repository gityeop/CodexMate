import AppKit
import Combine
import KeyboardShortcuts
import UserNotifications

private final class CodexHomeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var codexDirectoryURL: URL

    init(defaultDirectoryURL: URL = CodexHomeStore.defaultDirectoryURL()) {
        codexDirectoryURL = defaultDirectoryURL.standardizedFileURL
    }

    var currentDirectoryURL: URL {
        lock.lock()
        defer { lock.unlock() }
        return codexDirectoryURL
    }

    func update(codexHomePath: String?) {
        guard let codexHomePath else { return }

        let trimmedPath = codexHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }

        let expandedPath = (trimmedPath as NSString).expandingTildeInPath
        let directoryURL = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL

        lock.lock()
        codexDirectoryURL = directoryURL
        lock.unlock()
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum ServerRequestKind: Equatable {
        case toolUserInput
        case approval
        case other
    }

    private enum RetentionPolicy {
        static let threadReadMarkerSeconds: TimeInterval = 30 * 24 * 60 * 60
        static let pendingDiscoveredThreadSeconds: TimeInterval = 2 * 60
        static let maxPendingDiscoveredThreads = 64
    }

    private enum ForegroundRefreshPolicy {
        static let minimumInterval: TimeInterval = 1
    }

    private enum ThreadDiscoveryBoostPolicy {
        static let duration: TimeInterval = 10
        static let desktopActivityInterval: TimeInterval = 1
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
        static let visibleThreadLimit = 8
        static let maxProjectDisplayNameLength = 28
        static let maxThreadDisplayTitleLength = 44
    }

    private enum DefaultsKey {
        static let threadReadMarkers = "threadLastReadTerminalMarkers"
        static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
    }

    private enum MenuNavigationIdentifier {
        static let settings = "__codexmate_settings__"
    }

    private let openSettingsOnLaunch: Bool

    private var statusItem: NSStatusItem?
    private let menu = ThreadMenu()
    private let notchStatusOverlay = NotchStatusOverlayController()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let preferences = AppPreferencesStore()
    private let strings = AppStrings.shared
    private let client = CodexAppServerClient()
    private let codexHomeStore = CodexHomeStore()
    private lazy var desktopActivityService = DesktopActivityService(
        codexDirectoryURLProvider: { [codexHomeStore] in
            codexHomeStore.currentDirectoryURL
        }
    )
    private let launchAtLoginService = LaunchAtLoginService()
    private let updaterService = UpdaterService()
    private let statusSpriteCatalog = MenubarStatusSpriteCatalog()
    private let debugStatusOverride = DebugStatusOverride.overallStatus()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForUserIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")
    private let hoverTooltipController = ThreadHoverTooltipController()
    private let defaults = UserDefaults.standard
    private lazy var appServerRecentThreadListing = AppServerRecentThreadListing(
        client: client,
        fetchPageLimit: ThreadListDisplay.fetchPageLimit
    )
    private lazy var recentThreadListing = FallbackRecentThreadListing(
        primary: appServerRecentThreadListing,
        fallback: DesktopStateRecentThreadListing(
            codexDirectoryURLProvider: { [codexHomeStore] in
                codexHomeStore.currentDirectoryURL
            }
        )
    )
    private lazy var desktopThreadMetadataReader = DesktopStateThreadMetadataReader(
        codexDirectoryURLProvider: { [codexHomeStore] in
            codexHomeStore.currentDirectoryURL
        }
    )
    private lazy var asyncProjectCatalogLoader = DesktopProjectCatalogLoader(
        codexDirectoryURLProvider: { [codexHomeStore] in
            codexHomeStore.currentDirectoryURL
        }
    )
    private lazy var controller = MenubarController(
        desktopActivityLoader: desktopActivityService,
        recentThreadListing: recentThreadListing,
        threadMetadataReader: desktopThreadMetadataReader,
        projectCatalogLoader: asyncProjectCatalogLoader,
        initialThreadReadMarkers: AppDelegate.loadThreadReadMarkers(),
        configuration: MenubarControllerConfiguration(
            initialFetchLimit: ThreadListDisplay.initialFetchLimit,
            maxTrackedThreads: ThreadListDisplay.maxTrackedThreads,
            projectLimit: preferences.projectLimit,
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
    private var isSettingsWindowVisible = false
    private var isInitialThreadBootstrapInProgress = false
    private var pendingThreadRefreshAfterBootstrap = false
    private var fastThreadDiscoveryRefreshUntil: Date?
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
    private var optionShortcutTargetIDs: [String] = []
    private var threadProjectIndexByThreadID: [String: Int] = [:]
    private var pendingMenuBarPositionedThreadID: String?
    private var skipNextMenuBarMenuWillOpenRender = false
    private var foregroundRefreshObserverTokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var loggedUnhandledServerRequestMethods: Set<String> = []
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
    private lazy var settingsWindowController: SettingsWindowController = {
        let controller = SettingsWindowController(viewModel: settingsViewModel)
        controller.onVisibilityChanged = { [weak self] isVisible in
            guard let self else { return }
            self.isSettingsWindowVisible = isVisible
            self.debugLog("settingsWindowVisibilityChanged visible=\(isVisible)")

            if self.currentEffectiveDisplayMode == .notch {
                self.updateNotchStatusPanel()
            }
        }
        return controller
    }()
    private lazy var menuToggleController = MenuToggleController(
        openMenu: { [weak self] in
            self?.openMenu()
        },
        closeMenu: { [weak self] in
            self?.closeMenu()
        }
    )

    init(openSettingsOnLaunch: Bool = false) {
        self.openSettingsOnLaunch = openSettingsOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching log=\(DebugTraceLogger.logFileURL.path)")
        if let debugStatusOverride {
            debugLog("debugStatusOverride value=\(debugStatusOverride.displayName)")
        }
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

        if shouldOpenSettingsOnLaunch() {
            openSettingsAction()
        }

        Task {
            await connectAndLoad()
        }
    }

    private func shouldOpenSettingsOnLaunch() -> Bool {
        if openSettingsOnLaunch {
            return true
        }

        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return false
        }

        if defaults.bool(forKey: DefaultsKey.hasCompletedFirstLaunch) {
            return false
        }

        defaults.set(true, forKey: DefaultsKey.hasCompletedFirstLaunch)
        return true
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
        let nextMode = preferences.displayMode.resolved(hasHardwareNotch: preferredOverlayScreen() != nil)
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

        guard !isSettingsWindowVisible else {
            notchStatusOverlay.hide()
            return
        }

        guard let screen = preferredOverlayScreen() else {
            notchStatusOverlay.hide()
            return
        }

        if notchStatusOverlay.isMenuExpanded {
            notchStatusOverlay.showMenu(on: screen)
        } else {
            notchStatusOverlay.show(on: screen)
        }
    }

    private func preferredOverlayScreen() -> NSScreen? {
        if let hardwareNotchScreen = NSScreen.screens.first(where: \.hasCameraHousing) {
            return hardwareNotchScreen
        }

        if let builtInDisplay = NSScreen.screens.first(where: \.isBuiltInDisplay) {
            return builtInDisplay
        }

        return NSScreen.main ?? NSScreen.screens.first
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
        NotificationCenter.default.publisher(for: .appLanguageDidChange, object: preferences)
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

        preferences.$projectLimit
            .dropFirst()
            .sink { [weak self] _ in
                self?.renderMenu()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appDisplayModeDidChange, object: preferences)
            .sink { [weak self] _ in
                guard let self else { return }
                self.debugLog(
                    "displayModeChanged requested=\(self.preferences.displayMode.rawValue) effective=\(self.preferences.displayMode.resolved(hasHardwareNotch: self.preferredOverlayScreen() != nil).rawValue)"
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
        isInitialThreadBootstrapInProgress = true
        controller.setConnection(.connecting)
        renderMenu()

        do {
            let binaryURL = try CodexBinaryLocator.locate()
            let initializeResponse = try await client.start(codexBinaryURL: binaryURL)
            codexHomeStore.update(codexHomePath: initializeResponse.codexHome)
            connectedBinaryPath = binaryURL.path
            controller.setConnection(.connected(binaryPath: binaryURL.path))
            renderMenu()

            do {
                try await loadInitialThreads()
            } catch {
                completeInitialThreadBootstrap(requestBackfill: false)
                controller.recordDiagnostic("Initial thread load failed: \(error.localizedDescription)")
                renderMenu()
                scheduleRefreshTimerIfNeeded()
                armFastThreadDiscoveryRefreshWindow()
                requestDesktopActivityRefresh()
                requestThreadRefresh()
                requestInitialSubscriptionWarmup()
                return
            }

            armFastThreadDiscoveryRefreshWindow()
            scheduleRefreshTimerIfNeeded()
            requestDesktopActivityRefresh()
            requestInitialSubscriptionWarmup()
        } catch {
            completeInitialThreadBootstrap(requestBackfill: false)
            controller.recordDiagnostic("Initial app-server connection failed; continuing desktop-state refresh via fallback")
            controller.setConnection(.failed(message: error.localizedDescription))
            renderMenu()
            scheduleRefreshTimerIfNeeded()
            requestDesktopActivityRefresh()
            requestThreadRefresh()
        }
    }

    private func refreshThreads() async throws {
        let effects = try await controller.refreshThreads()
        if await client.isConnected() {
            markConnectionHealthy()
        }
        applyControllerEffects(effects)
        await reconcileLiveSubscriptions()
        renderMenu()
    }

    private func loadInitialThreads() async throws {
        try await controller.loadInitialThreads()
        if await client.isConnected() {
            markConnectionHealthy()
        }
        renderMenu()
        completeInitialThreadBootstrap(requestBackfill: true)
    }

    private func handleClientTermination(reason: String?) {
        liveSubscribedThreadUpdatedAtByID.removeAll()
        completeInitialThreadBootstrap(requestBackfill: false)

        let message = reason ?? "app-server process exited"
        controller.recordDiagnostic("app-server terminated; continuing desktop-state refresh via fallback")
        controller.setConnection(.failed(message: message))
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh()
        requestThreadRefresh()
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
            if Self.shouldHandleNotificationAsServerRequest(method) {
                handleServerRequest(method: method, payload: payload)
                return
            }
        }

        renderMenu()
    }

    private func handleServerRequest(method: String, payload: Data) {
        switch Self.classifyServerRequestMethod(method) {
        case .toolUserInput:
            guard let request = decodeServerRequestPayload(payload, as: ToolRequestUserInputRequest.self) else {
                controller.recordDiagnostic("server request decode failed method=\(method)")
                renderMenu()
                return
            }

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
        case .approval:
            guard let request = decodeServerRequestPayload(payload, as: ApprovalRequestPayload.self) else {
                controller.recordDiagnostic("server request decode failed method=\(method)")
                renderMenu()
                return
            }

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
        case .other:
            if loggedUnhandledServerRequestMethods.insert(method).inserted {
                controller.recordDiagnostic("unhandled server request method=\(method)")
            }
        }

        renderMenu()
    }

    nonisolated static func classifyServerRequestMethod(_ method: String) -> ServerRequestKind {
        let normalized = normalizedServerRequestMethodComponent(method)

        switch normalized {
        case "requestuserinput":
            return .toolUserInput
        case "requestapproval":
            return .approval
        default:
            return .other
        }
    }

    nonisolated static func shouldHandleNotificationAsServerRequest(_ method: String) -> Bool {
        classifyServerRequestMethod(method) != .other
    }

    private nonisolated static func normalizedServerRequestMethodComponent(_ method: String) -> String {
        let lastComponent = method.split(separator: "/").last.map(String.init) ?? method
        return lastComponent
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private func decodeServerRequestPayload<T: Decodable>(_ payload: Data, as type: T.Type) -> T? {
        guard let message = try? JSONDecoder().decode(WireMessage<T>.self, from: payload) else {
            return nil
        }

        return message.params
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
        armFastThreadDiscoveryRefreshWindow(now: now)
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
        let basePolicy = RefreshSchedulingPolicy.current(
            isMenuOpen: isMenuOpen,
            overallStatus: controller.overallStatus,
            hasRecentThreads: !controller.recentThreads.isEmpty
        )

        let now = Date()
        guard let fastThreadDiscoveryRefreshUntil,
              fastThreadDiscoveryRefreshUntil > now
        else {
            self.fastThreadDiscoveryRefreshUntil = nil
            return basePolicy
        }

        return RefreshSchedulingPolicy(
            desktopActivityInterval: min(
                basePolicy.desktopActivityInterval,
                ThreadDiscoveryBoostPolicy.desktopActivityInterval
            ),
            threadListInterval: basePolicy.threadListInterval
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
        guard !isSettingsWindowVisible else {
            notchStatusOverlay.hide()
            return
        }

        guard let overlayScreen = preferredOverlayScreen() else {
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
            frameIndex: statusAnimationFrameIndex
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
            projectLimit: preferences.projectLimit,
            visibleThreadLimit: preferences.threadsPerProjectLimit
        )
        let snapshot = preparedSnapshot.snapshot
        let menuSections = ThreadMenuBuilder.build(
            snapshotSections: snapshot.projectSections,
            recentThreads: controller.recentThreads,
            projectCatalog: controller.projectCatalog,
            projectLimit: preferences.projectLimit,
            visibleThreadLimit: preferences.threadsPerProjectLimit
        )
        var threadProjectIndexByThreadID: [String: Int] = [:]
        for (index, section) in menuSections.enumerated() {
            for threadID in flattenedThreadIDs(from: section.threads) {
                threadProjectIndexByThreadID[threadID] = index
            }
        }

        projectShortcutThreadIDs = menuSections.compactMap { $0.threads.first?.thread.id }
        optionShortcutTargetIDs = projectShortcutThreadIDs + [MenuNavigationIdentifier.settings]
        threadProjectIndexByThreadID[MenuNavigationIdentifier.settings] = projectShortcutThreadIDs.count
        self.threadProjectIndexByThreadID = threadProjectIndexByThreadID
        let renderThreadIDs = Set(flattenedThreadIDs(from: menuSections.flatMap(\.threads)))
        let hasUnreadThreads = menuSections.flatMap(\.threads).contains(where: hasUnreadContent(in:))
        let statusOverride = debugStatusOverride
        renderStatusItem(
            overallStatus: statusOverride ?? snapshot.overallStatus,
            hasUnreadThreads: statusOverride == nil ? hasUnreadThreads : false
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
        let isShowingLoadingPlaceholder = isInitialThreadBootstrapInProgress && controller.recentThreads.isEmpty

        if isShowingLoadingPlaceholder {
            menu.addItem(makeStaticItem(title: strings.text("menu.loadingRecentThreads", language: preferences.language)))
        } else if menuSections.isEmpty {
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
                        keyEquivalent: threadIndex == 0 ? ProjectMenuShortcut.keyEquivalent(for: index) : nil
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
        let settingsItem = makeActionItem(
            title: strings.text("menu.settings", language: preferences.language),
            action: #selector(openSettingsAction)
        )
        settingsItem.representedObject = MenuNavigationIdentifier.settings
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(
            makeActionItem(
                title: strings.text("menu.quit", language: preferences.language),
                action: #selector(quit)
            )
        )
        menu.addItem(
            makeHiddenShortcutItem(
                action: #selector(moveToPreviousProjectSelectionAction),
                keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                modifierMask: [.option]
            )
        )
        menu.addItem(
            makeHiddenShortcutItem(
                action: #selector(moveToNextProjectSelectionAction),
                keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                modifierMask: [.option]
            )
        )
        if currentEffectiveDisplayMode == .notch, isMenuOpen {
            notchStatusOverlay.setMenuItems(overlayMenuEntries(from: menu.items))
        }
        scheduleRefreshTimerIfNeeded()
    }

    private func overlayMenuEntries(from menuItems: [NSMenuItem]) -> [NotchStatusOverlayMenuEntry] {
        menuItems.compactMap(overlayMenuEntry(for:))
    }

    private func overlayMenuEntry(for item: NSMenuItem) -> NotchStatusOverlayMenuEntry? {
        if item.isHidden {
            return nil
        }

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
        let indicatorText = overlayIndicatorText(for: indicatorImage)
        let indentationLevel = item.indentationLevel
        let isEnabled = item.isEnabled
        let representedIdentifier = item.representedObject as? String
        let projectIndex = representedIdentifier.flatMap { threadProjectIndexByThreadID[$0] }

        let onSelect: (() -> Void)? = { [weak self] in
            guard let self else { return }
            guard let action else { return }

            self.debugLog(
                "overlay entry selection title=\(item.title) action=\(NSStringFromSelector(action)) represented=\(String(describing: item.representedObject)) event=\(self.debugEventSummary(NSApp.currentEvent))"
            )

            switch action {
            case #selector(openThread(_:)):
                guard let representedThreadID = representedIdentifier else { return }
                self.debugLog("overlay entry openThread thread=\(representedThreadID)")
                self.openThread(threadID: representedThreadID)
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
            identifier: representedIdentifier,
            indicatorText: indicatorText,
            indicatorImage: indicatorImage,
            navigationIndex: projectIndex,
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

    private func makeHiddenShortcutItem(
        action: Selector,
        keyEquivalent: String,
        modifierMask: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        item.keyEquivalentModifierMask = modifierMask
        return item
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
        let hasUnreadContent = hasUnreadContent(in: thread)
        let threadSnapshot = MenubarThreadSnapshot(thread: thread.thread, hasUnreadContent: hasUnreadContent)
        let title = menuTitle(for: thread)
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
        item.image = indicatorImage(for: thread, threadSnapshot: threadSnapshot)
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

    private func menuTitle(for thread: ThreadMenuThread) -> String {
        let relativeDate = relativeDateFormatter.localizedString(for: thread.thread.activityUpdatedAt, relativeTo: Date())
        return MenubarStatusPresentation.threadTitle(
            for: thread.thread,
            relativeDate: relativeDate,
            maxDisplayTitleLength: ThreadListDisplay.maxThreadDisplayTitleLength,
            strings: strings,
            language: preferences.language
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

    private func overlayIndicatorText(for indicatorImage: NSImage?) -> String? {
        if indicatorImage === unreadIndicatorImage {
            return MenubarStatusPresentation.threadIndicatorText(for: .unread)
        }

        if indicatorImage === runningIndicatorImage {
            return MenubarStatusPresentation.threadIndicatorText(for: .running)
        }

        if indicatorImage === waitingForUserIndicatorImage {
            return MenubarStatusPresentation.threadIndicatorText(for: .waitingForUser)
        }

        if indicatorImage === failedIndicatorImage {
            return MenubarStatusPresentation.threadIndicatorText(for: .failed)
        }

        return nil
    }

    private func indicatorImage(
        for thread: ThreadMenuThread,
        threadSnapshot: MenubarThreadSnapshot
    ) -> NSImage? {
        let indicator = MenubarStatusPresentation.threadIndicator(
            for: threadSnapshot.thread,
            hasUnreadContent: threadSnapshot.hasUnreadContent
        )

        switch indicator {
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
        if isInitialThreadBootstrapInProgress {
            pendingThreadRefreshAfterBootstrap = true
            return
        }

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
            openMenuBarMenu(positioningThreadID: nil, requestRefresh: true)
        case .notch:
            guard let screen = preferredOverlayScreen() else {
                applyPresentationMode()
                return
            }

            guard !isSettingsWindowVisible else {
                isMenuOpen = false
                menuToggleController.menuDidClose()
                settingsWindowController.showWindow(nil)
                return
            }

            debugLog("openMenu mode=notch screen=\(screen.localizedName)")
            hideHoverTooltip()
            isMenuOpen = true
            armFastThreadDiscoveryRefreshWindow()
            KeyboardShortcuts.disable(.toggleMenuBarDropdown)
            installMenuShortcutEventMonitor()
            installMenuDismissEventMonitors()
            menuToggleController.menuWillOpen()
            renderMenu()
            scheduleRefreshTimerIfNeeded()
            requestDesktopActivityRefresh()
            requestThreadRefresh()
            notchStatusOverlay.showMenu(on: screen)
        case nil:
            applyPresentationMode(force: true)
            openMenu()
        }
    }

    private func openMenuBarMenu(positioningThreadID: String?, requestRefresh: Bool) {
        debugLog(
            "openMenuBarMenu positioningThreadID=\(positioningThreadID ?? "nil") requestRefresh=\(requestRefresh)"
        )
        hideHoverTooltip()
        renderMenu()
        if requestRefresh {
            requestDesktopActivityRefresh()
            requestThreadRefresh()
        }
        configureStatusItemForMenuBarMode()

        guard let button = statusItem?.button,
              let positioningThreadID,
              let positioningItem = menu.items.first(where: { ($0.representedObject as? String) == positioningThreadID }) else {
            statusItem?.button?.performClick(nil)
            return
        }

        highlightedThreadID = hoverTooltipContentsByThreadID[positioningThreadID] == nil ? nil : positioningThreadID
        skipNextMenuBarMenuWillOpenRender = true
        menu.popUp(positioning: positioningItem, at: NSPoint(x: button.bounds.midX, y: button.bounds.minY), in: button)
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

            if self.handleNotchMenuKeyboardEvent(event) {
                return nil
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
        case .openHighlightedItem:
            return activateHighlightedMenuItem()
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
        case let .movePrimarySelection(delta):
            return moveProjectSelection(by: delta)
        }
    }

    private func activateHighlightedMenuItem() -> Bool {
        guard let item = highlightedMenuItem(),
              let action = item.action else {
            return false
        }

        switch action {
        case #selector(openThread(_:)):
            guard let threadID = item.representedObject as? String else {
                return false
            }

            openThread(threadID: threadID)
            return true
        case #selector(openSettingsAction):
            openSettingsAction()
            return true
        case #selector(quit):
            quit()
            return true
        default:
            return NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    private func highlightedMenuItem() -> NSMenuItem? {
        if let highlightedItem = menu.highlightedItem,
           highlightedItem.isEnabled,
           highlightedItem.action != nil {
            return highlightedItem
        }

        guard let highlightedThreadID else {
            return nil
        }

        return menu.items.first(where: { ($0.representedObject as? String) == highlightedThreadID })
    }

    private func moveProjectSelection(by delta: Int) -> Bool {
        switch currentEffectiveDisplayMode {
        case .menuBar:
            return moveMenuBarProjectSelection(by: delta)
        case .notch:
            return notchStatusOverlay.moveExpandedMenuPrimarySelection(delta)
        case nil:
            return false
        }
    }

    private func moveMenuBarProjectSelection(by delta: Int) -> Bool {
        guard isMenuOpen, !optionShortcutTargetIDs.isEmpty else {
            return false
        }

        let currentThreadID = (menu.highlightedItem?.representedObject as? String) ?? highlightedThreadID
        guard let targetThreadID = menuBarProjectTargetThreadID(from: currentThreadID, delta: delta) else {
            return false
        }

        if targetThreadID == currentThreadID {
            return true
        }

        pendingMenuBarPositionedThreadID = targetThreadID
        closeMenu()
        return true
    }

    private func menuBarProjectTargetThreadID(from currentThreadID: String?, delta: Int) -> String? {
        guard !optionShortcutTargetIDs.isEmpty else {
            return nil
        }

        let targetProjectIndex: Int
        if let currentThreadID,
           let currentProjectIndex = threadProjectIndexByThreadID[currentThreadID] {
            targetProjectIndex = (currentProjectIndex + delta + optionShortcutTargetIDs.count) % optionShortcutTargetIDs.count
        } else {
            targetProjectIndex = delta > 0 ? 0 : optionShortcutTargetIDs.count - 1
        }

        guard optionShortcutTargetIDs.indices.contains(targetProjectIndex) else {
            return nil
        }

        return optionShortcutTargetIDs[targetProjectIndex]
    }

    @objc
    private func moveToPreviousProjectSelectionAction() {
        _ = moveProjectSelection(by: -1)
    }

    @objc
    private func moveToNextProjectSelectionAction() {
        _ = moveProjectSelection(by: 1)
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

        if currentEffectiveDisplayMode == .notch,
           notchStatusOverlay.handleExpandedMenuKeyEvent(event) {
            debugLog("overlay shortcut handledByNotchMenu keyCode=\(event.keyCode)")
            return true
        }

        guard let action = ThreadMenu.shortcutAction(for: event) else {
            return false
        }

        debugLog("overlay shortcut action=\(action)")
        return handleMenuKeyboardShortcut(action)
    }

    private func handleNotchMenuKeyboardEvent(_ event: NSEvent) -> Bool {
        guard currentEffectiveDisplayMode == .notch, isMenuOpen else {
            return false
        }

        return notchStatusOverlay.handleExpandedMenuKeyEvent(event)
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
    private func openSettingsAction() {
        debugLog("openSettingsAction")
        if currentEffectiveDisplayMode == .notch {
            isSettingsWindowVisible = true
            notchStatusOverlay.hide()
        }
        closeMenu()
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
        armFastThreadDiscoveryRefreshWindow()
        if skipNextMenuBarMenuWillOpenRender {
            skipNextMenuBarMenuWillOpenRender = false
        } else {
            renderMenu()
        }
        KeyboardShortcuts.disable(.toggleMenuBarDropdown)
        installMenuShortcutEventMonitor()
        menuToggleController.menuWillOpen()
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh()
        requestThreadRefresh()
    }

    private func completeInitialThreadBootstrap(requestBackfill: Bool) {
        let shouldRequestBackfill = pendingThreadRefreshAfterBootstrap || requestBackfill
        isInitialThreadBootstrapInProgress = false
        pendingThreadRefreshAfterBootstrap = false

        guard shouldRequestBackfill else {
            return
        }

        requestThreadRefresh()
    }

    private func armFastThreadDiscoveryRefreshWindow(now: Date = Date()) {
        let boostedUntil = now.addingTimeInterval(ThreadDiscoveryBoostPolicy.duration)
        if let fastThreadDiscoveryRefreshUntil, fastThreadDiscoveryRefreshUntil >= boostedUntil {
            return
        }

        fastThreadDiscoveryRefreshUntil = boostedUntil
        scheduleRefreshTimerIfNeeded()
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

        if let pendingMenuBarPositionedThreadID {
            self.pendingMenuBarPositionedThreadID = nil
            DispatchQueue.main.async { [weak self] in
                self?.openMenuBarMenu(positioningThreadID: pendingMenuBarPositionedThreadID, requestRefresh: false)
            }
        }
    }
}
