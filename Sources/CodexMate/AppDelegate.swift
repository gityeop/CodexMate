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

private enum UserNotificationPayloadKey {
    static let threadID = "threadID"
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

    private enum WeeklyUsageRefreshPolicy {
        static let refreshInterval: TimeInterval = 5 * 60
    }

    private enum NotificationRenderPolicy {
        static let coalescingDelayNanoseconds: UInt64 = 100_000_000
    }

    private enum DesktopPrunePolicy {
        static let minimumInterval: TimeInterval = 30
    }

    private enum ThreadDiscoveryBoostPolicy {
        static let duration: TimeInterval = 10
        static let desktopActivityInterval: TimeInterval = 1
        static let threadListInterval: TimeInterval = 1
    }

    private enum StatusAnimation {
        static let frameInterval: TimeInterval = 0.12
        static let loadingFrameInterval: TimeInterval = 1.0 / 24.0
    }

    private enum ThreadListDisplay {
        static let initialFetchLimit = 32
        static let maxTrackedThreads = 256
        static let visibleThreadLimit = 8
        static let maxProjectDisplayNameLength = 28
        static let maxThreadDisplayTitleLength = 44
    }

    private enum RuntimeMode {
        static let localConnectionDescription = "local desktop state"
    }

    private enum DefaultsKey {
        static let threadReadMarkers = "threadLastReadTerminalMarkers"
        static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
    }

    private enum MenuNavigationIdentifier {
        static let settings = "__codexmate_settings__"
    }

    private let openSettingsOnLaunch: Bool
    private let promoMockupEnabled: Bool
    private let promoMockupDisplayMode: AppDisplayMode

    private var statusItem: NSStatusItem?
    private let menu = ThreadMenu()
    private let notchStatusOverlay = NotchStatusOverlayController()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let preferences = AppPreferencesStore()
    private let strings = AppStrings.shared
    private let codexHomeStore = CodexHomeStore()
    private lazy var desktopActivityService = DesktopActivityService(
        codexDirectoryURLProvider: { [codexHomeStore] in
            codexHomeStore.currentDirectoryURL
        }
    )
    private let launchAtLoginService = LaunchAtLoginService()
    private let updaterService = UpdaterService()
    private let statusSpriteCatalog = MenubarStatusSpriteCatalog()
    private lazy var initialThreadBootstrapLoadingFrames = AppDelegate.makeLoadingIndicatorFrames(
        pointSize: NotchStatusOverlayController.Metrics.spritePointSize
    )
    private let debugStatusOverride = DebugStatusOverride.overallStatus()
    private let unreadIndicatorImage = AppDelegate.makeUnreadIndicatorImage()
    private let runningIndicatorImage = AppDelegate.makeTextIndicatorImage("⏳")
    private let waitingForUserIndicatorImage = AppDelegate.makeTextIndicatorImage("💬")
    private let failedIndicatorImage = AppDelegate.makeTextIndicatorImage("⚠️")
    private let hoverTooltipController = ThreadHoverTooltipController()
    private let defaults = UserDefaults.standard
    private let weeklyUsageService = WeeklyUsageService()
    private lazy var localDesktopRecentThreadListing = DesktopStateRecentThreadListing(
        codexDirectoryURLProvider: { [codexHomeStore] in
            codexHomeStore.currentDirectoryURL
        }
    )
    private lazy var localDesktopThreadMetadataReader = DesktopStateThreadMetadataReader(
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
        recentThreadListing: localDesktopRecentThreadListing,
        threadMetadataReader: localDesktopThreadMetadataReader,
        projectCatalogLoader: asyncProjectCatalogLoader,
        initialThreadReadMarkers: AppDelegate.loadThreadReadMarkers(),
        configuration: MenubarControllerConfiguration(
            initialFetchLimit: ThreadListDisplay.initialFetchLimit,
            maxTrackedThreads: ThreadListDisplay.maxTrackedThreads,
            projectLimit: preferences.projectLimit,
            visibleThreadLimit: ThreadListDisplay.visibleThreadLimit,
            authoritativeListOmissionGraceCount: 2,
            maxPendingDiscoveredThreads: RetentionPolicy.maxPendingDiscoveredThreads,
            pendingDiscoveredThreadTTL: RetentionPolicy.pendingDiscoveredThreadSeconds,
            threadReadMarkerRetentionSeconds: RetentionPolicy.threadReadMarkerSeconds
        )
    )
    private var pendingThreadMetadataRefreshIDs: Set<String> = []
    private var refreshTimer: Timer?
    private var refreshTimerInterval: TimeInterval?
    private var weeklyUsageRefreshTimer: Timer?
    private var weeklyUsageRefreshTask: Task<Void, Never>?
    private var currentWeeklyUsage: WeeklyUsageReading?
    private var currentWeeklyUsageErrorMessage: String?
    private var currentStatusSprite: MenubarStatusPresentation.StatusSprite = .connecting
    private var currentStatusDisplayName = AppStateStore.OverallStatus.connecting.displayName
    private var currentNotchStatusContent = MenubarStatusPresentation.notchStatusContent(
        overallStatus: .connecting,
        hasUnreadThreads: false
    )
    private var currentStatusTextIcon = AppStateStore.OverallStatus.connecting.icon
    private var currentEffectiveDisplayMode: AppDisplayMode?
    private var isMenuOpen = false
    private var isSettingsWindowVisible = false
    private var isInitialThreadBootstrapInProgress = false
    private var pendingThreadRefreshAfterBootstrap = false
    private var fastThreadDiscoveryRefreshUntil: Date?
    private var lastDesktopActivityRefreshRequestAt: Date?
    private var lastThreadRefreshRequestAt: Date?
    private var lastDesktopPruneAt: Date?
    private var desktopActivityRefreshGate = RefreshRequestGate()
    private var desktopActivityRefreshTask: Task<Void, Never>?
    private var threadRefreshGate = RefreshRequestGate()
    private var threadRefreshTask: Task<Void, Never>?
    private var threadMetadataRefreshTask: Task<Void, Never>?
    private var notificationRenderTask: Task<Void, Never>?
    private var threadNotificationStatusByThreadID: [String: AppStateStore.ThreadStatus] = [:]
    private var shouldRefreshDesktopActivityAfterNextThreadRefresh = false
    private var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
    private var hoverTooltipWorkItem: DispatchWorkItem?
    private var highlightedThreadID: String?
    private var menuBarFocusedThreadID: String?
    private var menuBarNavigationIdentifier: String?
    private var projectShortcutThreadIDs: [String] = []
    private var optionShortcutTargetIDs: [String] = []
    private var threadProjectIndexByThreadID: [String: Int] = [:]
    private var pendingMenuBarPositionedThreadID: String?
    private var handledMenuBarModifiedArrowEventSignature: String?
    private var skipNextMenuBarMenuWillOpenRender = false
    private var skipNextMenuBarMenuWillOpenRefresh = false
    private var foregroundRefreshObserverTokens: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var loggedUnhandledServerRequestMethods: Set<String> = []
    private var loggedUnhandledThreadNotificationMethods: Set<String> = []
    private var isShowingAccessibilityPermissionAlert = false
    private var foregroundRefreshThrottle = ForegroundRefreshThrottle(
        minimumInterval: ForegroundRefreshPolicy.minimumInterval
    )
    private var menuBarModifiedArrowEventTap: CFMachPort?
    private var menuBarModifiedArrowEventTapRunLoopSource: CFRunLoopSource?
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
        canOpenMenu: { [weak self] in
            self?.canOpenMenuFromToggle() ?? false
        },
        openMenu: { [weak self] in
            self?.openMenu()
        },
        closeMenu: { [weak self] in
            self?.closeMenu()
        }
    )

    init(
        openSettingsOnLaunch: Bool = false,
        promoMockupEnabled: Bool = false,
        promoMockupDisplayMode: AppDisplayMode = .menuBar
    ) {
        self.openSettingsOnLaunch = openSettingsOnLaunch
        self.promoMockupEnabled = promoMockupEnabled
        self.promoMockupDisplayMode = promoMockupDisplayMode
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
        debugLog("menuBarNavigationImplementation=event-tap-sync-physical-modifier-v2")
        configureMainMenu()
        configureNotchStatusPanel()
        configurePreferencesObservers()
        configureGlobalShortcut()
        relativeDateFormatter.locale = preferences.locale
        applyPresentationMode(force: true)
        requestAccessibilityPermissionIfNeeded()
        startWeeklyUsageUpdates()

        if promoMockupEnabled {
            isInitialThreadBootstrapInProgress = false
            renderMenu()
            DispatchQueue.main.async { [weak self] in
                self?.openPromoMockupMenu()
            }
            return
        }

        configureForegroundRefreshObservers()
        requestNotificationPermission()

#if DEBUG
        if CommandLine.arguments.contains("--notification-qa") {
            isInitialThreadBootstrapInProgress = false
            controller.setConnection(.connected(binaryPath: "notification QA"))
            renderMenu()
            scheduleAgentNotificationQA()
            return
        }
#endif

        isInitialThreadBootstrapInProgress = true
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

    private var requestedDisplayMode: AppDisplayMode {
        promoMockupEnabled ? promoMockupDisplayMode : preferences.displayMode
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugLog("applicationWillTerminate event=\(debugEventSummary(NSApp.currentEvent))")
        removeForegroundRefreshObservers()
        invalidateTimers()
        cancelNotificationRenderTask()
        removeMenuBarModifiedArrowEventTap()
        removeMenuShortcutEventMonitor()
        removeMenuDismissEventMonitors()
        stopWeeklyUsageUpdates()
        notchStatusOverlay.hide()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        debugLog("applicationShouldTerminate event=\(debugEventSummary(NSApp.currentEvent))")
        return .terminateNow
    }

    private func applyPresentationMode(force: Bool = false) {
        let displayMode = requestedDisplayMode
        let nextMode = displayMode.resolved(hasHardwareNotch: preferredOverlayScreen() != nil)
        let previousMode = currentEffectiveDisplayMode

        debugLog(
            "applyPresentationMode force=\(force) requested=\(displayMode.rawValue) previous=\(previousMode?.rawValue ?? "nil") next=\(nextMode.rawValue)"
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
            notchStatusOverlay.hide()
        case .notch:
            removeStatusItem()
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
                guard let self else { return }
                self.renderMenu()
                self.requestThreadRefresh()
            }
            .store(in: &cancellables)

        preferences.$threadListSectionLimit
            .dropFirst()
            .sink { [weak self] _ in
                self?.renderMenu()
            }
            .store(in: &cancellables)

        preferences.$projectLimit
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.renderMenu()
                self.requestThreadRefresh()
            }
            .store(in: &cancellables)

        preferences.$threadListViewMode
            .dropFirst()
            .sink { [weak self] _ in
                self?.renderMenu()
            }
            .store(in: &cancellables)

        preferences.$notchStatusContentEnabled
            .dropFirst()
            .sink { [weak self] _ in
                self?.applyStatusPresentation()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appDisplayModeDidChange, object: preferences)
            .sink { [weak self] _ in
                guard let self else { return }
                self.debugLog(
                    "displayModeChanged requested=\(self.requestedDisplayMode.rawValue) effective=\(self.requestedDisplayMode.resolved(hasHardwareNotch: self.preferredOverlayScreen() != nil).rawValue)"
                )
                self.applyPresentationMode()
                self.requestAccessibilityPermissionIfNeeded()
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

    private func requestNotificationPermission() {
        guard notificationsEnabled else {
            controller.recordDiagnostic("User notifications are disabled outside an .app bundle.")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.debugLog("User notification authorization failed: \(error.localizedDescription)")
                }
                return
            }

            guard granted else {
                Task { @MainActor [weak self] in
                    self?.debugLog("User notification authorization denied.")
                }
                return
            }
        }
    }

#if DEBUG
    private func scheduleAgentNotificationQA() {
        let mainThreadID = "notification-qa-main"
        let subagentThreadID = "notification-qa-subagent"
        let now = Int(Date().timeIntervalSince1970)
        let mainThread = CodexThread(
            id: mainThreadID,
            preview: "QA Main Agent — should notify",
            createdAt: now,
            updatedAt: now,
            status: .active(flags: []),
            cwd: "/tmp/CodexMate-Notification-QA",
            name: "QA Main Agent — should notify"
        )
        let subagentThread = CodexThread(
            id: subagentThreadID,
            preview: "QA Subagent — must stay silent",
            createdAt: now,
            updatedAt: now,
            status: .active(flags: []),
            cwd: "/tmp/CodexMate-Notification-QA",
            name: "QA Subagent — must stay silent",
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"notification-qa-main","depth":1,"agent_path":null,"agent_nickname":"QA Teammate","agent_role":"explorer"}}}"#,
            agentRole: "explorer",
            agentNickname: "QA Teammate"
        )

        applyNotification(.threadStarted(ThreadStartedNotification(thread: mainThread)))
        applyNotification(.threadStarted(ThreadStartedNotification(thread: subagentThread)))
        renderMenu()
        debugLog("notification QA scheduled main=\(mainThreadID) subagent=\(subagentThreadID)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.completeNotificationQAThread(threadID: mainThreadID, turnID: "notification-qa-main-turn")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.completeNotificationQAThread(threadID: subagentThreadID, turnID: "notification-qa-subagent-turn")
        }
    }

    private func completeNotificationQAThread(threadID: String, turnID: String) {
        applyNotification(
            .turnCompleted(
                TurnCompletedNotification(
                    threadId: threadID,
                    turn: CodexTurn(id: turnID, status: .completed, error: nil)
                )
            )
        )
        sendThreadDesktopNotification(
            ThreadDesktopNotification(threadID: threadID, kind: .completion)
        )
        renderMenu()
    }
#endif

    private func requestAccessibilityPermissionIfNeeded() {
        guard currentEffectiveDisplayMode == .menuBar else {
            return
        }

        guard !AccessibilityPermission.isTrusted(prompt: false) else {
            return
        }

        presentAccessibilityPermissionAlert(
            requestSystemPrompt: true,
            diagnostic: "Accessibility permission missing for menu bar keyboard monitoring."
        )
    }

    @discardableResult
    private func requireAccessibilityPermissionForMenuBarKeyboardMonitoring() -> Bool {
        guard currentEffectiveDisplayMode == .menuBar else {
            return true
        }

        guard AccessibilityPermission.isTrusted(prompt: false) else {
            presentAccessibilityPermissionAlert(
                requestSystemPrompt: true,
                diagnostic: "Menu bar keyboard monitoring blocked: Accessibility permission missing."
            )
            return false
        }

        return true
    }

    private func presentAccessibilityPermissionAlert(requestSystemPrompt: Bool, diagnostic: String) {
        debugLog(diagnostic)

        guard !isShowingAccessibilityPermissionAlert else {
            return
        }

        isShowingAccessibilityPermissionAlert = true
        if requestSystemPrompt {
            _ = AccessibilityPermission.isTrusted(prompt: true)
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = strings.text("permission.accessibility.title", language: preferences.language)
        alert.informativeText = strings.text("permission.accessibility.message", language: preferences.language)
        alert.addButton(withTitle: strings.text("permission.accessibility.openSettings", language: preferences.language))
        alert.addButton(withTitle: strings.text("permission.accessibility.notNow", language: preferences.language))

        let response = alert.runModal()
        isShowingAccessibilityPermissionAlert = false

        if response == .alertFirstButtonReturn {
            AccessibilityPermission.openSettings()
        }
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

        controller.setConnection(.connected(binaryPath: RuntimeMode.localConnectionDescription))
        shouldRefreshDesktopActivityAfterNextThreadRefresh = true
        renderMenu()

        do {
            try await loadInitialThreads()
        } catch {
            completeInitialThreadBootstrap(requestBackfill: false)
            controller.recordDiagnostic("Initial local thread load failed: \(error.localizedDescription)")
            renderMenu()
            scheduleRefreshTimerIfNeeded()
            armFastThreadDiscoveryRefreshWindow()
            requestDesktopActivityRefresh()
            requestThreadRefresh()
            return
        }

        armFastThreadDiscoveryRefreshWindow()
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh()
    }

    private func refreshThreads() async throws {
        let effects = try await controller.refreshThreads()
        let pruneEffects = await controller.pruneThreadsMissingFromDesktopState()
        let shouldFollowUpWithDesktopActivity = shouldRefreshDesktopActivityAfterNextThreadRefresh
        shouldRefreshDesktopActivityAfterNextThreadRefresh = false
        applyControllerEffects(effects)
        applyControllerEffects(pruneEffects)
        sendNotificationsForThreadStatusChanges()
        renderMenu()
        if shouldFollowUpWithDesktopActivity {
            requestDesktopActivityRefresh()
        }
    }

    private func loadInitialThreads() async throws {
        try await controller.loadInitialThreads(
            projectLimit: preferences.projectLimit,
            visibleThreadLimit: preferences.threadsPerProjectLimit
        )
        syncThreadNotificationStatusBaseline()
        completeInitialThreadBootstrap(requestBackfill: true)
        renderMenu()
    }

    private func handleClientTermination(reason: String?) {
        completeInitialThreadBootstrap(requestBackfill: false)

        let message = reason ?? "app-server process exited"
        controller.recordDiagnostic("app-server terminated; authoritative thread list unavailable until reconnect")
        controller.setConnection(.failed(message: message))
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh()
        requestThreadRefresh()
        renderMenu()
    }

    private func handleClientMessage(_ message: ClientMessage) {
        switch message {
        case let .notification(method, payload):
            if handleNotification(method: method, payload: payload) {
                syncThreadNotificationStatusBaseline()
                scheduleNotificationRender()
            }
        case let .request(_, method, payload):
            handleServerRequest(method: method, payload: payload)
        case let .diagnostic(text):
            controller.recordDiagnostic(text)
            renderMenu()
        }
    }

    private func handleNotification(method: String, payload: Data) -> Bool {
        switch method {
        case "thread/started":
            decodeAndApply(payload, as: ThreadStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.threadStarted(notification))
                debugLog("received thread/started thread=\(shortThreadID(notification.thread.id))")
                trackActivityThread(
                    notification.thread.id,
                    boostDiscovery: true,
                    requestThreadMetadataRefresh: true
                )
            }
        case "thread/status/changed":
            decodeAndApply(payload, as: ThreadStatusChangedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.threadStatusChanged(notification))
                trackActivityThread(notification.threadId)
            }
        case "thread/archived":
            decodeAndApply(payload, as: ThreadArchivedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.threadArchived(notification))
                armFastThreadDiscoveryRefreshWindow()
                requestThreadRefresh()
            }
        case "thread/unarchived":
            decodeAndApply(payload, as: ThreadUnarchivedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.threadUnarchived(notification))
                trackActivityThread(
                    notification.threadId,
                    boostDiscovery: true,
                    requestThreadMetadataRefresh: true
                )
            }
        case "thread/name/updated":
            decodeAndApply(payload, as: ThreadNameUpdatedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.threadNameUpdated(notification))
                trackActivityThread(notification.threadId)
            }
        case "turn/started":
            decodeAndApply(payload, as: TurnStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.turnStarted(notification))
                trackActivityThread(
                    notification.threadId,
                    boostDiscovery: true,
                    requestThreadMetadataRefresh: true
                )
            }
        case "item/started":
            decodeAndApply(payload, as: ItemStartedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.itemStarted(notification))
                trackActivityThread(notification.threadId)
            }
        case "turn/completed":
            decodeAndApply(payload, as: TurnCompletedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.turnCompleted(notification))
                trackActivityThread(
                    notification.threadId,
                    requestThreadMetadataRefresh: true
                )
                requestDesktopActivityRefresh()
                if preferences.completionNotificationsEnabled {
                    sendThreadDesktopNotification(
                        ThreadDesktopNotification(
                            threadID: notification.threadId,
                            kind: .completion
                        )
                    )
                }
            }
        case "error":
            decodeAndApply(payload, as: ErrorNotificationPayload.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.error(notification))
                trackActivityThread(notification.threadId, requestThreadMetadataRefresh: true)
                requestDesktopActivityRefresh()

                if !notification.willRetry && preferences.failureNotificationsEnabled {
                    sendThreadDesktopNotification(
                        ThreadDesktopNotification(
                            threadID: notification.threadId,
                            kind: .failure(message: notification.error.message)
                        )
                    )
                }
            }
        case "serverRequest/resolved":
            decodeAndApply(payload, as: ServerRequestResolvedNotification.self) { [weak self] notification in
                guard let self else { return }
                applyNotification(.serverRequestResolved(notification))
                trackActivityThread(notification.threadId)
            }
        case "thread/closed":
            decodeAndApply(payload, as: ThreadClosedNotification.self) { [weak self] notification in
                guard let self else { return }
                controller.markUnwatched(threadIDs: Set([notification.threadId]))
                requestThreadRefresh()
            }
        default:
            if Self.shouldHandleNotificationAsServerRequest(method) {
                handleServerRequest(method: method, payload: payload)
                return false
            }

            if method.hasPrefix("thread/") {
                if Self.shouldIgnoreThreadNotification(method) {
                    return false
                }

                if loggedUnhandledThreadNotificationMethods.insert(method).inserted {
                    debugLog("received unhandled thread notification method=\(method)")
                    controller.recordDiagnostic("Unhandled thread notification: \(method)")
                    requestThreadRefresh()
                    return true
                }
                return false
            }
        }

        return true
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
            trackActivityThread(
                request.threadId,
                boostDiscovery: true,
                requestThreadMetadataRefresh: true
            )
            controller.recordDiagnostic("user-input request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
            if preferences.attentionNotificationsEnabled {
                sendThreadDesktopNotification(
                    ThreadDesktopNotification(
                        threadID: request.threadId,
                        kind: .attention(.waitingForInput)
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
            trackActivityThread(
                request.threadId,
                boostDiscovery: true,
                requestThreadMetadataRefresh: true
            )
            controller.recordDiagnostic("approval request method=\(method) thread=\(request.threadId.prefix(8)) turn=\(request.turnId.prefix(8))")
            if preferences.attentionNotificationsEnabled {
                sendThreadDesktopNotification(
                    ThreadDesktopNotification(
                        threadID: request.threadId,
                        kind: .attention(.needsApproval)
                    )
                )
            }
        case .other:
            if loggedUnhandledServerRequestMethods.insert(method).inserted {
                controller.recordDiagnostic("unhandled server request method=\(method)")
            }
        }

        syncThreadNotificationStatusBaseline()
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

    nonisolated static func shouldIgnoreThreadNotification(_ method: String) -> Bool {
        method == "thread/tokenUsage/updated"
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

    private func syncThreadNotificationStatusBaseline() {
        threadNotificationStatusByThreadID = ThreadNotificationPlanner.statusByThreadID(
            from: controller.recentThreads
        )
    }

    private func sendNotificationsForThreadStatusChanges() {
        guard !isInitialThreadBootstrapInProgress else {
            syncThreadNotificationStatusBaseline()
            return
        }

        let notifications = ThreadNotificationPlanner.notifications(
            previousStatusByThreadID: threadNotificationStatusByThreadID,
            currentRows: controller.recentThreads
        )
        syncThreadNotificationStatusBaseline()

        for notification in notifications {
            sendThreadDesktopNotification(notification)
        }
    }

    private func sendThreadDesktopNotification(_ notification: ThreadDesktopNotification) {
        let body: String

        switch notification.kind {
        case let .attention(status):
            guard preferences.attentionNotificationsEnabled else { return }
            switch status {
            case .waitingForInput:
                body = strings.text("notification.needsInput.body", language: preferences.language)
            case .needsApproval:
                body = strings.text("notification.approval.body", language: preferences.language)
            case .notLoaded, .idle, .running, .failed:
                return
            }
        case .completion:
            guard preferences.completionNotificationsEnabled else { return }
            body = ""
        case let .failure(message):
            guard preferences.failureNotificationsEnabled else { return }
            if let message, !message.isEmpty {
                body = message
            } else {
                body = strings.text("notification.error.body", language: preferences.language)
            }
        }

        guard let thread = controller.recentThreads.first(where: { $0.id == notification.threadID }) else {
            debugLog("User notification missing metadata thread=\(notification.threadID) kind=\(String(describing: notification.kind))")
            return
        }
        guard ThreadNotificationPlanner.allowsNotifications(for: thread) else {
            debugLog("User notification suppressed for ineligible thread=\(notification.threadID) kind=\(String(describing: notification.kind))")
            return
        }

        let content = ThreadNotificationContentBuilder.content(
            body: body,
            metadata: notificationMetadata(for: thread),
            kind: notification.kind
        )
        sendNotification(
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            threadID: notification.threadID
        )
    }

    private func notificationMetadata(for thread: AppStateStore.ThreadRow) -> ThreadNotificationMetadata {
        let project = controller.projectCatalog.project(forThreadID: thread.id, cwd: thread.cwd)
        return ThreadNotificationMetadata(
            projectDisplayName: project.displayName,
            threadTitle: thread.displayTitle,
            replySnippet: ThreadNotificationContentBuilder.latestAssistantReplySnippet(sessionPath: thread.sessionPath)
        )
    }

    private func sendNotification(title: String, subtitle: String, body: String, threadID: String) {
        guard notificationsEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = [
            UserNotificationPayloadKey.threadID: threadID
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.debugLog("User notification failed thread=\(threadID): \(error.localizedDescription)")
            }
        }
    }

    private func handleForegroundRefreshNotification(_ name: Notification.Name, now: Date = Date()) {
        guard foregroundRefreshThrottle.shouldTrigger(now: now) else {
            return
        }

        controller.recordDiagnostic("foreground refresh via \(name.rawValue)")
        armFastThreadDiscoveryRefreshWindow(now: now)
        scheduleRefreshTimerIfNeeded()
        requestDesktopActivityRefresh(now: now)
        requestThreadRefresh(now: now)
    }

    private func startWeeklyUsageUpdates() {
        guard weeklyUsageRefreshTimer == nil else {
            return
        }

        requestWeeklyUsageRefresh()
        let timer = Timer(
            timeInterval: WeeklyUsageRefreshPolicy.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.requestWeeklyUsageRefresh()
            }
        }
        weeklyUsageRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWeeklyUsageUpdates() {
        weeklyUsageRefreshTimer?.invalidate()
        weeklyUsageRefreshTimer = nil
        weeklyUsageRefreshTask?.cancel()
        weeklyUsageRefreshTask = nil

        Task {
            await weeklyUsageService.stop()
        }
    }

    private func requestWeeklyUsageRefresh() {
        guard weeklyUsageRefreshTask == nil else {
            return
        }

        weeklyUsageRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.weeklyUsageRefreshTask = nil
            }

            do {
                let reading = try await self.weeklyUsageService.read()
                self.currentWeeklyUsage = reading
                self.currentWeeklyUsageErrorMessage = nil
                self.debugLog(
                    "Weekly usage refresh succeeded remaining=\(reading.remainingPercent) resetsAt=\(reading.resetsAt?.timeIntervalSince1970.description ?? "nil") readAt=\(reading.readAt.timeIntervalSince1970)"
                )
            } catch is CancellationError {
                return
            } catch {
                self.currentWeeklyUsage = nil
                self.currentWeeklyUsageErrorMessage = error.localizedDescription
                self.debugLog("Weekly usage refresh failed: \(error.localizedDescription)")
            }

            if self.isMenuOpen {
                self.renderMenu()
            }
        }
    }

    private var notificationsEnabled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private func scheduleRefreshTimerIfNeeded() {
        guard !promoMockupEnabled else {
            return
        }

        let policy = refreshSchedulingPolicy()
        guard refreshTimer == nil || refreshTimerInterval != policy.timerInterval else {
            return
        }

        invalidateTimers()
        refreshTimerInterval = policy.timerInterval
        let timer = Timer(
            timeInterval: policy.timerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleRefreshTimerTick()
            }
        }
        refreshTimer = timer
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
            threadListInterval: min(
                basePolicy.threadListInterval,
                ThreadDiscoveryBoostPolicy.threadListInterval
            )
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

    private func scheduleNotificationRender() {
        guard notificationRenderTask == nil else {
            return
        }

        notificationRenderTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: NotificationRenderPolicy.coalescingDelayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            notificationRenderTask = nil
            renderMenu()
        }
    }

    private func cancelNotificationRenderTask() {
        notificationRenderTask?.cancel()
        notificationRenderTask = nil
    }

    private func refreshDesktopActivity() async {
        let effects = await controller.refreshDesktopActivity()
        let pruneEffects: MenubarControllerEffects
        if shouldPruneDesktopThreads(now: Date()) {
            pruneEffects = await controller.pruneThreadsMissingFromDesktopState()
        } else {
            pruneEffects = MenubarControllerEffects()
        }
        applyControllerEffects(effects)
        applyControllerEffects(pruneEffects)
        sendNotificationsForThreadStatusChanges()
        renderMenu()
    }

    private func renderStatusItem(overallStatus: AppStateStore.OverallStatus, hasUnreadThreads: Bool) {
        let sprite = MenubarStatusPresentation.statusItemSprite(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads
        )
        if sprite != currentStatusSprite {
            currentStatusSprite = sprite
        }

        currentStatusDisplayName = MenubarStatusPresentation.statusDisplayName(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads,
            strings: strings,
            language: preferences.language
        )
        currentNotchStatusContent = MenubarStatusPresentation.notchStatusContent(
            overallStatus: overallStatus,
            hasUnreadThreads: hasUnreadThreads,
            strings: strings,
            language: preferences.language
        )
        currentStatusTextIcon = MenubarStatusPresentation.statusItemIcon(
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
        button.title = currentStatusTextIcon
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

        let isShowingInitialThreadBootstrapLoading = isInitialThreadBootstrapInProgress
        let spriteImages = isShowingInitialThreadBootstrapLoading
            ? initialThreadBootstrapLoadingFrames
            : statusSpriteCatalog.notchFrames(
                for: currentStatusSprite,
                renderedPixelSize: 128,
                renderedPointSize: NotchStatusOverlayController.Metrics.spritePointSize
            )
        let statusContent: MenubarStatusPresentation.NotchStatusContent
        if !preferences.notchStatusContentEnabled {
            statusContent = .empty
        } else if isShowingInitialThreadBootstrapLoading {
            statusContent = MenubarStatusPresentation.NotchStatusContent(
                primaryText: "Load",
                secondaryText: strings.text("menu.loadingRecentThreads", language: preferences.language),
                dotTone: .amber
            )
        } else {
            statusContent = currentNotchStatusContent
        }

        notchStatusOverlay.update(
            spriteImages: spriteImages,
            statusSprite: currentStatusSprite,
            statusContent: statusContent,
            frameInterval: isShowingInitialThreadBootstrapLoading
                ? StatusAnimation.loadingFrameInterval
                : StatusAnimation.frameInterval,
            animationIdentifier: isShowingInitialThreadBootstrapLoading ? "initial_thread_bootstrap_loading" : nil,
            forceAnimation: isShowingInitialThreadBootstrapLoading
        )
        if !notchStatusOverlay.isVisible {
            notchStatusOverlay.show(on: overlayScreen)
        }
    }

    private func renderMenu() {
        hoverTooltipWorkItem?.cancel()
        hoverTooltipWorkItem = nil

        guard isMenuOpen else {
            renderCurrentStatusItem()
            scheduleRefreshTimerIfNeeded()
            return
        }

        let focusedThreadIDBeforeRender = selectedMenuBarThreadID()
        let preparedSnapshot = promoMockupEnabled
            ? PromoMockupMenu.preparedSnapshot()
            : controller.prepareSnapshot(
                projectLimit: preferences.projectLimit,
                visibleThreadLimit: currentThreadListLimit,
                threadListViewMode: preferences.threadListViewMode,
                pinnedThreadIDs: preferences.pinnedThreadIDs
            )
        let snapshot = preparedSnapshot.snapshot
        let menuSections = snapshot.menuSections
        updateMenuNavigationState(menuSections: menuSections)
        let didChangeReadMarkers = preparedSnapshot.didChangeReadMarkers
        if didChangeReadMarkers {
            persistThreadReadMarkers()
        }
        renderCurrentStatusItem()

        var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
        menu.removeAllItems()
        menu.addItem(makeWeeklyUsageMenuItem())
        for item in visibleThreadMenuItems(
            snapshot: snapshot,
            menuSections: menuSections,
            hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID
        ) {
            menu.addItem(item)
        }

        self.hoverTooltipContentsByThreadID = hoverTooltipContentsByThreadID
        let restoredFocusedThreadID = focusedThreadIDBeforeRender.flatMap { threadID in
            hoverTooltipContentsByThreadID[threadID] == nil ? nil : threadID
        }
        menuBarFocusedThreadID = restoredFocusedThreadID
        highlightedThreadID = restoredFocusedThreadID
        menuBarNavigationIdentifier = restoredFocusedThreadID
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
        addHiddenMenuActivationShortcutItems()
        if currentEffectiveDisplayMode == .notch, isMenuOpen {
            notchStatusOverlay.setMenuItems(overlayMenuEntries(from: menu.items))
        }
        scheduleRefreshTimerIfNeeded()
    }

    private func addHiddenMenuActivationShortcutItems() {
        for keyEquivalent in ["\r", "\u{3}"] {
            menu.addItem(
                makeHiddenShortcutItem(
                    action: #selector(activateHighlightedMenuItemAction),
                    keyEquivalent: keyEquivalent,
                    modifierMask: []
                )
            )
        }
    }

    private func updateMenuNavigationState(menuSections: [ThreadMenuSection]) {
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
    }

    private func visibleThreadMenuItems(
        snapshot: MenubarSnapshot,
        menuSections: [ThreadMenuSection],
        hoverTooltipContentsByThreadID: inout [String: MenubarStatusPresentation.ThreadTooltipContent]
    ) -> [NSMenuItem] {
        let isShowingLoadingPlaceholder = isInitialThreadBootstrapInProgress && !snapshot.hasRecentThreads
        if isShowingLoadingPlaceholder {
            return [makeStaticItem(title: strings.text("menu.loadingRecentThreads", language: preferences.language))]
        }

        if menuSections.isEmpty {
            return [makeStaticItem(title: strings.text("menu.noRecentThreads", language: preferences.language))]
        }

        var menuItems: [NSMenuItem] = []
        for (index, section) in menuSections.enumerated() {
            if index > 0 {
                menuItems.append(.separator())
            }

            menuItems.append(makeStaticItem(title: projectSectionTitle(for: section)))

            for (threadIndex, thread) in section.threads.enumerated() {
                appendThreadMenuItems(
                    thread,
                    level: 0,
                    worktreeDisplayName: section.displayName,
                    hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID,
                    keyEquivalent: threadIndex == 0 ? ProjectMenuShortcut.keyEquivalent(for: index) : nil,
                    menuItems: &menuItems
                )
            }
        }

        return menuItems
    }

    private func renderCurrentStatusItem() {
        if promoMockupEnabled {
            let statusSnapshot = PromoMockupMenu.statusSnapshot()
            renderStatusItem(
                overallStatus: statusSnapshot.overallStatus,
                hasUnreadThreads: statusSnapshot.hasUnreadThreads
            )
            return
        }

        let statusOverride = debugStatusOverride
        let statusSnapshot = controller.prepareStatusSnapshot(
            visibleThreadLimit: currentThreadListLimit,
            threadListViewMode: preferences.threadListViewMode,
            pinnedThreadIDs: preferences.pinnedThreadIDs
        )
        renderStatusItem(
            overallStatus: statusOverride ?? statusSnapshot.overallStatus,
            hasUnreadThreads: statusOverride == nil ? statusSnapshot.hasUnreadThreads : false
        )
    }

    private var currentThreadListLimit: Int {
        switch preferences.threadListViewMode {
        case .projects:
            return preferences.threadsPerProjectLimit
        case .recent, .status:
            return preferences.threadListSectionLimit
        }
    }

    private func overlayMenuEntries(from menuItems: [NSMenuItem]) -> [NotchStatusOverlayMenuEntry] {
        menuItems.compactMap(overlayMenuEntry(for:))
    }

    private func overlayMenuEntry(for item: NSMenuItem) -> NotchStatusOverlayMenuEntry? {
        if item.isHidden {
            return nil
        }

        if let weeklyUsageView = item.view as? WeeklyUsageIndicatorView {
            return .weeklyUsage(weeklyUsageView.presentation)
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
                self.debugLog("overlay entry dispatch action=\(NSStringFromSelector(action))")
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

    private func makeWeeklyUsageMenuItem() -> NSMenuItem {
        let remainingPercent = currentWeeklyUsage?.remainingPercent
        let indicatorView = WeeklyUsageIndicatorView(
            remainingPercent: remainingPercent,
            resetsAt: currentWeeklyUsage?.resetsAt,
            errorMessage: currentWeeklyUsageErrorMessage,
            language: preferences.language
        )
        let item = NSMenuItem(
            title: indicatorView.accessibilityText,
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false

        let intrinsicSize = indicatorView.intrinsicContentSize
        indicatorView.frame = NSRect(origin: .zero, size: intrinsicSize)
        item.view = indicatorView
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
        if thread.hasUnreadContent {
            return true
        }

        return thread.children.contains(where: hasUnreadContent(in:))
    }

    private func appendThreadMenuItems(
        _ thread: ThreadMenuThread,
        level: Int,
        worktreeDisplayName: String,
        hoverTooltipContentsByThreadID: inout [String: MenubarStatusPresentation.ThreadTooltipContent],
        keyEquivalent: String? = nil,
        menuItems: inout [NSMenuItem]
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
        menuItems.append(item)

        for child in thread.children {
            appendThreadMenuItems(
                child,
                level: level + 1,
                worktreeDisplayName: worktreeDisplayName,
                hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID,
                keyEquivalent: nil,
                menuItems: &menuItems
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
        menuBarNavigationIdentifier = item?.representedObject as? String

        if let item {
            let representedThreadID = item.representedObject as? String
            menuBarFocusedThreadID = representedThreadID.flatMap { threadID in
                hoverTooltipContentsByThreadID[threadID] == nil ? nil : threadID
            }
        }

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

    private func applyNotification(_ notification: AppStateStore.NotificationEvent) {
        if controller.apply(notification: notification) {
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

        if effects.didChangeThreadReadMarkers {
            persistThreadReadMarkers()
        }

        if effects.shouldBoostThreadDiscovery {
            armFastThreadDiscoveryRefreshWindow()
        }

        if effects.shouldRequestDesktopActivityRefresh {
            requestDesktopActivityRefresh(force: false)
        }

        if effects.shouldRequestDesktopActivityAfterThreadRefresh {
            shouldRefreshDesktopActivityAfterNextThreadRefresh = true
        }

        if effects.shouldRequestThreadRefresh {
            requestThreadRefresh(force: false)
        }
    }

    private func shouldPruneDesktopThreads(now: Date) -> Bool {
        guard let lastDesktopPruneAt else {
            self.lastDesktopPruneAt = now
            return true
        }

        guard now.timeIntervalSince(lastDesktopPruneAt) >= DesktopPrunePolicy.minimumInterval else {
            return false
        }

        self.lastDesktopPruneAt = now
        return true
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

    private static func makeLoadingIndicatorFrames(pointSize: NSSize) -> [NSImage] {
        let frameCount = 24
        let dotCount = 3
        let side = min(pointSize.width, pointSize.height)
        let dotSize = max(4, side * 0.2)
        let gap = max(5, side * 0.18)
        let totalWidth = dotSize * CGFloat(dotCount) + gap * CGFloat(dotCount - 1)
        let baseX = (pointSize.width - totalWidth) / 2
        let baseY = (pointSize.height - dotSize) / 2
        let lift = side * 0.12
        let delayByDot = 0.18

        return (0..<frameCount).map { frameIndex in
            let image = NSImage(size: pointSize)
            image.lockFocus()

            let time = Double(frameIndex) / Double(frameCount)

            for dotIndex in 0..<dotCount {
                let delayedTime = time - (Double(dotIndex) * delayByDot)
                let phase = delayedTime - floor(delayedTime)
                let pulse = 0.5 - (cos(CGFloat(phase) * 2 * .pi) * 0.5)
                let rect = NSRect(
                    x: baseX + CGFloat(dotIndex) * (dotSize + gap),
                    y: baseY + (pulse * lift),
                    width: dotSize,
                    height: dotSize
                )
                let alpha = 0.25 + (pulse * 0.75)

                NSColor(calibratedRed: 0.44, green: 0.66, blue: 1, alpha: alpha).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }

            image.unlockFocus()
            image.isTemplate = false
            return image
        }
    }

    private func requestThreadRefresh(force: Bool = true, now: Date = Date()) {
        guard !promoMockupEnabled else {
            return
        }

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
                    requestThreadRefresh(force: false, now: Date())
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
        guard !promoMockupEnabled else {
            return
        }

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
                    requestDesktopActivityRefresh(force: false, now: Date())
                }
            }

            await refreshDesktopActivity()
        }
    }

    private func trackActivityThread(
        _ threadID: String,
        boostDiscovery: Bool = false,
        requestThreadMetadataRefresh: Bool = false,
        now: Date = Date()
    ) {
        if boostDiscovery {
            armFastThreadDiscoveryRefreshWindow(now: now)
        }

        if requestThreadMetadataRefresh {
            requestLiveThreadMetadataRefresh(threadID: threadID, now: now)
        }
    }

    private func requestLiveThreadMetadataRefresh(threadID: String, now: Date = Date()) {
        pendingThreadMetadataRefreshIDs.insert(threadID)
        requestThreadRefresh(force: false, now: now)

        guard threadMetadataRefreshTask == nil else {
            return
        }

        threadMetadataRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: NotificationRenderPolicy.coalescingDelayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            let threadIDs = self.pendingThreadMetadataRefreshIDs
            self.pendingThreadMetadataRefreshIDs.removeAll()
            self.threadMetadataRefreshTask = nil

            guard !threadIDs.isEmpty else { return }
            let effects = await self.controller.refreshThreadMetadata(threadIDs: threadIDs)
            self.applyControllerEffects(effects)
            self.renderMenu()
        }
    }

    private func openPromoMockupMenu() {
        switch currentEffectiveDisplayMode {
        case .menuBar:
            openMenuBarMenu(positioningThreadID: nil, requestRefresh: false)
        case .notch:
            openMenu()
        case nil:
            applyPresentationMode(force: true)
            openPromoMockupMenu()
        }
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

    private func canOpenMenuFromToggle() -> Bool {
        guard currentEffectiveDisplayMode == .notch, isInitialThreadBootstrapInProgress else {
            return true
        }

        debugLog("menu toggle ignored while initial thread bootstrap is in progress")
        return false
    }

    private func openMenuBarMenu(positioningThreadID: String?, requestRefresh: Bool) {
        debugLog(
            "openMenuBarMenu positioningThreadID=\(positioningThreadID ?? "nil") requestRefresh=\(requestRefresh)"
        )
        guard requireAccessibilityPermissionForMenuBarKeyboardMonitoring() else {
            return
        }

        hideHoverTooltip()
        renderMenu()
        if requestRefresh {
            skipNextMenuBarMenuWillOpenRefresh = true
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
        menuBarFocusedThreadID = highlightedThreadID
        menuBarNavigationIdentifier = positioningThreadID
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

    private func installMenuBarModifiedArrowEventTap() {
        guard menuBarModifiedArrowEventTap == nil,
              menuBarModifiedArrowEventTapRunLoopSource == nil else {
            return
        }

        guard AccessibilityPermission.isTrusted(prompt: false) else {
            presentAccessibilityPermissionAlert(
                requestSystemPrompt: true,
                diagnostic: "Failed to install menu bar modified-arrow event tap: Accessibility permission missing."
            )
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                AppDelegate.handleMenuBarModifiedArrowEventTapCallback(
                    type: type,
                    event: event,
                    userInfo: userInfo
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            presentAccessibilityPermissionAlert(
                requestSystemPrompt: true,
                diagnostic: "Failed to install menu bar modified-arrow event tap."
            )
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        menuBarModifiedArrowEventTap = eventTap
        menuBarModifiedArrowEventTapRunLoopSource = runLoopSource
        debugLog("menuBar modifiedArrowEventTap installed")
    }

    private func removeMenuBarModifiedArrowEventTap() {
        if let eventTap = menuBarModifiedArrowEventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource = menuBarModifiedArrowEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        if menuBarModifiedArrowEventTap != nil {
            debugLog("menuBar modifiedArrowEventTap removed")
        }

        menuBarModifiedArrowEventTap = nil
        menuBarModifiedArrowEventTapRunLoopSource = nil
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
        case let .moveBoundarySelection(delta):
            return moveProjectSelectionToBoundary(delta)
        case .togglePinnedThread:
            return togglePinnedSelectedThread()
        }
    }

    private func togglePinnedSelectedThread() -> Bool {
        guard let threadID = selectedThreadIDForPinToggle() else {
            debugLog("pin toggle failed: no selected thread")
            return false
        }

        let isPinned = preferences.togglePinnedThread(threadID: threadID)
        debugLog("pin toggle thread=\(threadID) pinned=\(isPinned)")

        if currentEffectiveDisplayMode == .menuBar, isMenuOpen {
            refreshOpenMenuBarThreadItems(focusedThreadID: threadID)
            return true
        }

        renderMenu()
        if currentEffectiveDisplayMode == .notch {
            notchStatusOverlay.flashMenuItem(identifier: threadID)
        }
        return true
    }

    private func refreshOpenMenuBarThreadItems(focusedThreadID: String) {
        let preparedSnapshot = promoMockupEnabled
            ? PromoMockupMenu.preparedSnapshot()
            : controller.prepareSnapshot(
                projectLimit: preferences.projectLimit,
                visibleThreadLimit: currentThreadListLimit,
                threadListViewMode: preferences.threadListViewMode,
                pinnedThreadIDs: preferences.pinnedThreadIDs
            )
        let snapshot = preparedSnapshot.snapshot
        let menuSections = snapshot.menuSections
        updateMenuNavigationState(menuSections: menuSections)
        if preparedSnapshot.didChangeReadMarkers {
            persistThreadReadMarkers()
        }

        var hoverTooltipContentsByThreadID: [String: MenubarStatusPresentation.ThreadTooltipContent] = [:]
        let visibleItems = visibleThreadMenuItems(
            snapshot: snapshot,
            menuSections: menuSections,
            hoverTooltipContentsByThreadID: &hoverTooltipContentsByThreadID
        )
        replaceVisibleThreadMenuItems(visibleItems)
        self.hoverTooltipContentsByThreadID = hoverTooltipContentsByThreadID

        if hoverTooltipContentsByThreadID[focusedThreadID] == nil {
            menuBarFocusedThreadID = nil
            highlightedThreadID = nil
            menuBarNavigationIdentifier = nil
        } else {
            menuBarFocusedThreadID = focusedThreadID
            highlightedThreadID = focusedThreadID
            menuBarNavigationIdentifier = focusedThreadID
        }

        if hoverTooltipController.isVisible,
           let highlightedThreadID,
           let tooltipContent = hoverTooltipContentsByThreadID[highlightedThreadID] {
            hoverTooltipController.show(
                content: tooltipContent,
                near: NSEvent.mouseLocation,
                avoidingMenuWidth: menu.size.width,
                menuFrame: currentMenuFrame()
            )
        } else if hoverTooltipController.isVisible {
            hideHoverTooltip()
        }

        renderCurrentStatusItem()
        scheduleRefreshTimerIfNeeded()
    }

    private func replaceVisibleThreadMenuItems(_ visibleItems: [NSMenuItem]) {
        guard let weeklyUsageItem = menu.items.first,
              weeklyUsageItem.view is WeeklyUsageIndicatorView else {
            preconditionFailure("Weekly usage menu item missing.")
        }

        Self.replaceOpenMenuBarThreadItems(
            in: menu,
            weeklyUsageItem: weeklyUsageItem,
            settingsIdentifier: MenuNavigationIdentifier.settings,
            visibleItems: visibleItems
        )
    }

    static func replaceOpenMenuBarThreadItems(
        in menu: NSMenu,
        weeklyUsageItem: NSMenuItem,
        settingsIdentifier: String,
        visibleItems: [NSMenuItem]
    ) {
        guard menu.items.first === weeklyUsageItem else {
            preconditionFailure("Weekly usage menu item must remain first.")
        }

        guard let settingsIndex = menu.items.firstIndex(where: {
            ($0.representedObject as? String) == settingsIdentifier
        }) else {
            preconditionFailure("Settings menu item missing.")
        }

        let replaceableItemCount = settingsIndex - 1
        guard replaceableItemCount >= 0 else {
            preconditionFailure("Settings menu item must follow weekly usage.")
        }

        for _ in 0..<replaceableItemCount {
            menu.removeItem(at: 1)
        }

        let replacementItems = visibleItems + [.separator()]
        for (index, item) in replacementItems.enumerated() {
            menu.insertItem(item, at: index + 1)
        }
    }

    private func selectedThreadIDForPinToggle() -> String? {
        let candidateThreadID: String?

        switch currentEffectiveDisplayMode {
        case .menuBar:
            candidateThreadID = selectedMenuBarThreadID()
        case .notch:
            candidateThreadID = notchStatusOverlay.selectedExpandedMenuItemIdentifier()
        case nil:
            candidateThreadID = nil
        }

        guard let candidateThreadID,
              hoverTooltipContentsByThreadID[candidateThreadID] != nil else {
            return nil
        }

        return candidateThreadID
    }

    private func selectedMenuBarThreadID() -> String? {
        if let threadID = menu.highlightedItem?.representedObject as? String {
            return threadID
        }

        if let menuBarFocusedThreadID {
            return menuBarFocusedThreadID
        }

        if let highlightedThreadID {
            return highlightedThreadID
        }

        return highlightedMenuItem()?.representedObject as? String
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

    @objc
    private func activateHighlightedMenuItemAction() {
        _ = activateHighlightedMenuItem()
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

    private func moveProjectSelectionToBoundary(_ delta: Int) -> Bool {
        switch currentEffectiveDisplayMode {
        case .menuBar:
            return moveMenuBarProjectSelectionToBoundary(delta)
        case .notch:
            return notchStatusOverlay.moveExpandedMenuPrimarySelectionToBoundary(delta)
        case nil:
            return false
        }
    }

    private func moveMenuBarProjectSelection(by delta: Int) -> Bool {
        guard isMenuOpen, !optionShortcutTargetIDs.isEmpty else {
            return false
        }

        let currentThreadID = selectedMenuBarNavigationIdentifier()
        guard let targetThreadID = menuBarProjectTargetThreadID(from: currentThreadID, delta: delta) else {
            return false
        }

        return moveMenuBarProjectSelection(to: targetThreadID, currentThreadID: currentThreadID)
    }

    private func moveMenuBarProjectSelectionToBoundary(_ delta: Int) -> Bool {
        guard isMenuOpen else {
            return false
        }

        guard let targetItem = menuBarBoundarySelectionItem(delta) else {
            return false
        }

        if targetItem == menu.highlightedItem {
            return true
        }

        highlightMenuBarItem(targetItem)
        return true
    }

    private func moveMenuBarProjectSelection(to targetThreadID: String, currentThreadID: String?) -> Bool {
        if targetThreadID == currentThreadID {
            return true
        }

        highlightMenuBarItem(identifier: targetThreadID)
        return true
    }

    private func selectedMenuBarNavigationIdentifier() -> String? {
        (menu.highlightedItem?.representedObject as? String)
            ?? menuBarNavigationIdentifier
            ?? highlightedThreadID
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

    private func menuBarBoundarySelectionItem(_ delta: Int) -> NSMenuItem? {
        Self.menuBarBoundarySelectionItem(in: menu, delta: delta)
    }

    static func menuBarBoundarySelectionItem(in menu: NSMenu, delta: Int) -> NSMenuItem? {
        let selectableItems = menu.items.filter { item in
            item.isEnabled && !item.isHidden && !item.isSeparatorItem && item.action != nil
        }

        return delta > 0 ? selectableItems.last : selectableItems.first
    }

    private func menuBarTargetItem(
        for action: ThreadMenuKeyboardShortcutAction,
        currentThreadID: String?
    ) -> NSMenuItem? {
        switch action {
        case let .movePrimarySelection(delta):
            guard let targetThreadID = menuBarProjectTargetThreadID(from: currentThreadID, delta: delta) else {
                return nil
            }

            return menu.items.first(where: { ($0.representedObject as? String) == targetThreadID })
        case let .moveBoundarySelection(delta):
            return menuBarBoundarySelectionItem(delta)
        case .openHighlightedItem, .openProjectThread, .togglePinnedThread:
            return nil
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

        if currentEffectiveDisplayMode == .notch,
           notchStatusOverlay.handleExpandedMenuKeyEvent(event) {
            debugLog("overlay shortcut handledByNotchMenu keyCode=\(event.keyCode)")
            return true
        }

        if currentEffectiveDisplayMode == .menuBar {
            if handleMenuBarModifiedArrowKeyEquivalentEvent(event) {
                return true
            }

            if Self.isMenuBarModifiedArrowKeyEvent(event) {
                return false
            }
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
        if Self.shouldCopyThreadIDForOpenEvent(NSApp.currentEvent) {
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

        guard let appURL = CodexApplicationLocator.locate() else {
            debugLog("openThread missingAppURL thread=\(threadID)")
            controller.recordDiagnostic("Unable to open Codex deeplink for thread \(threadID).")
            renderMenu()
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", appURL.path, deepLinkURL.absoluteString]

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                debugLog("openThread openCommandExited thread=\(threadID) status=\(task.terminationStatus)")
                controller.recordDiagnostic("Failed to open Codex thread \(threadID): open exited with status \(task.terminationStatus)")
                renderMenu()
                return
            }

            debugLog("openThread launchedCodexApp thread=\(threadID) app=\(appURL.path)")
            markThreadRead(threadID)
            renderMenu()
        } catch {
            debugLog("openThread openCommandFailed thread=\(threadID) error=\(error.localizedDescription)")
            controller.recordDiagnostic("Failed to open Codex thread \(threadID): \(error.localizedDescription)")
            renderMenu()
        }
    }

    static func shouldCopyThreadIDForOpenEvent(_ event: NSEvent?) -> Bool {
        guard let event,
              event.modifierFlags.contains(.option) else {
            return false
        }

        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            return true
        default:
            return false
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
    enum MenuBarPhysicalModifier: Hashable, Sendable {
        case option
        case command
    }

    nonisolated static func menuBarModifiedArrowShortcutAction(
        for event: NSEvent,
        physicalModifiers: Set<MenuBarPhysicalModifier>
    ) -> ThreadMenuKeyboardShortcutAction? {
        guard event.type == .keyDown else {
            return nil
        }

        return menuBarModifiedArrowShortcutAction(
            keyCode: event.keyCode,
            physicalModifiers: physicalModifiers
        )
    }

    nonisolated static func menuBarModifiedArrowShortcutAction(
        keyCode: UInt16,
        physicalModifiers: Set<MenuBarPhysicalModifier>
    ) -> ThreadMenuKeyboardShortcutAction? {
        switch (physicalModifiers, keyCode) {
        case ([.option], 125):
            return .movePrimarySelection(1)
        case ([.option], 126):
            return .movePrimarySelection(-1)
        case ([.command], 125):
            return .moveBoundarySelection(1)
        case ([.command], 126):
            return .moveBoundarySelection(-1)
        default:
            return nil
        }
    }

    nonisolated private static func pressedMenuBarPhysicalModifiers() -> Set<MenuBarPhysicalModifier> {
        var modifiers = Set<MenuBarPhysicalModifier>()

        if CGEventSource.keyState(.combinedSessionState, key: 58)
            || CGEventSource.keyState(.combinedSessionState, key: 61) {
            modifiers.insert(.option)
        }

        if CGEventSource.keyState(.combinedSessionState, key: 55)
            || CGEventSource.keyState(.combinedSessionState, key: 54) {
            modifiers.insert(.command)
        }

        return modifiers
    }

    nonisolated private static func isMenuBarModifiedArrowKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == 125 || event.keyCode == 126 else {
            return false
        }

        let modifierFlags = event.modifierFlags
            .intersection([.command, .option, .control, .shift])
        return modifierFlags == .option || modifierFlags == .command
    }

    nonisolated private static func handleMenuBarModifiedArrowEventTapCallback(
        type: CGEventType,
        event: CGEvent,
        userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let action = menuBarModifiedArrowShortcutAction(
            keyCode: keyCode,
            physicalModifiers: pressedMenuBarPhysicalModifiers()
        ) else {
            return Unmanaged.passUnretained(event)
        }

        guard let userInfo else {
            preconditionFailure("Missing AppDelegate for menu bar modified-arrow event tap.")
        }

        let flagsRawValue = event.flags.rawValue
        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated {
            appDelegate.handleMenuBarModifiedArrowEventTapAction(
                action,
                keyCode: keyCode,
                flagsRawValue: flagsRawValue
            )
        }

        return nil
    }

    private func handleMenuBarModifiedArrowEventTapAction(
        _ action: ThreadMenuKeyboardShortcutAction,
        keyCode: UInt16,
        flagsRawValue: UInt64
    ) {
        guard currentEffectiveDisplayMode == .menuBar,
              isMenuOpen else {
            return
        }

        debugLog(
            "menuBar modifiedArrowEventTap keyCode=\(keyCode) physicalModifiers=\(Self.pressedMenuBarPhysicalModifiers()) flags=\(flagsRawValue) action=\(action)"
        )
        _ = handleMenuKeyboardShortcut(action)
    }

    private func handleMenuBarModifiedArrowKeyEquivalent(
        _ event: NSEvent,
        action: ThreadMenuKeyboardShortcutAction
    ) -> Bool {
        guard currentEffectiveDisplayMode == .menuBar,
              isMenuOpen,
              menuBarTargetItem(
                for: action,
                currentThreadID: selectedMenuBarNavigationIdentifier()
              ) != nil else {
            return false
        }

        let signature = menuBarModifiedArrowEventSignature(event)
        guard handledMenuBarModifiedArrowEventSignature != signature else {
            return true
        }

        debugLog(
            "menuBar modifiedArrowKeyEquivalent physicalModifiers=\(Self.pressedMenuBarPhysicalModifiers()) logicalFlags=\(event.modifierFlags.rawValue) action=\(action)"
        )
        handledMenuBarModifiedArrowEventSignature = signature
        return handleMenuKeyboardShortcut(action)
    }

    private func handleMenuBarModifiedArrowKeyEquivalentEvent(_ event: NSEvent) -> Bool {
        guard currentEffectiveDisplayMode == .menuBar,
              let menuBarAction = Self.menuBarModifiedArrowShortcutAction(
                for: event,
                physicalModifiers: Self.pressedMenuBarPhysicalModifiers()
              ) else {
            return false
        }

        debugLog("menuBar modifiedArrowKeyEquivalentEvent action=\(menuBarAction)")
        return handleMenuBarModifiedArrowKeyEquivalent(event, action: menuBarAction)
    }

    private func highlightMenuBarItem(identifier: String) {
        guard let item = menu.items.first(where: { ($0.representedObject as? String) == identifier }) else {
            preconditionFailure("Menu item missing for keyboard highlight: \(identifier)")
        }

        highlightMenuBarItem(item)
    }

    private func highlightMenuBarItem(_ item: NSMenuItem) {
        let selector = NSSelectorFromString("highlightItem:")
        precondition(menu.responds(to: selector), "NSMenu does not respond to highlightItem:")
        menu.perform(selector, with: item)
        updateHoverTooltip(for: item)
    }

    private func menuBarModifiedArrowEventSignature(_ event: NSEvent) -> String {
        "\(event.timestamp)|\(event.keyCode)|\(event.modifierFlags.rawValue)"
    }

    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        guard menu == self.menu else {
            return false
        }

        if currentEffectiveDisplayMode == .menuBar {
            if handleMenuBarModifiedArrowKeyEquivalentEvent(event) {
                return true
            }

            if Self.isMenuBarModifiedArrowKeyEvent(event) {
                return false
            }
        }

        guard let shortcutAction = ThreadMenu.shortcutAction(for: event) else {
            return false
        }

        if shortcutAction == .togglePinnedThread {
            _ = handleMenuKeyboardShortcut(shortcutAction)
            return false
        }

        return handleMenuKeyboardShortcut(shortcutAction)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == self.menu else { return }

        debugLog("menuWillOpen")
        hideHoverTooltip()
        menuBarFocusedThreadID = nil
        menuBarNavigationIdentifier = nil
        handledMenuBarModifiedArrowEventSignature = nil
        isMenuOpen = true
        armFastThreadDiscoveryRefreshWindow()
        if skipNextMenuBarMenuWillOpenRender {
            skipNextMenuBarMenuWillOpenRender = false
        } else {
            renderMenu()
        }
        KeyboardShortcuts.disable(.toggleMenuBarDropdown)
        if currentEffectiveDisplayMode == .menuBar {
            installMenuBarModifiedArrowEventTap()
        }
        installMenuShortcutEventMonitor()
        menuToggleController.menuWillOpen()
        scheduleRefreshTimerIfNeeded()
        if skipNextMenuBarMenuWillOpenRefresh {
            skipNextMenuBarMenuWillOpenRefresh = false
        } else {
            requestDesktopActivityRefresh()
            requestThreadRefresh()
        }
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
        menuBarFocusedThreadID = nil
        menuBarNavigationIdentifier = nil
        handledMenuBarModifiedArrowEventSignature = nil
        isMenuOpen = false
        removeMenuBarModifiedArrowEventTap()
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }

        let userInfo = response.notification.request.content.userInfo
        guard let threadID = userInfo[UserNotificationPayloadKey.threadID] as? String,
              !threadID.isEmpty else {
            Task { @MainActor [weak self] in
                self?.debugLog("User notification response missing thread id.")
            }
            completionHandler()
            return
        }

        Task { @MainActor [weak self] in
            self?.debugLog("User notification clicked thread=\(threadID)")
            self?.openThread(threadID: threadID)
        }
        completionHandler()
    }
}
