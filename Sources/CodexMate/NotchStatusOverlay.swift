import AppKit

fileprivate struct NotchStatusOverlayGeometry {
    let panelFrame: CGRect
    let hardwareNotchFrame: CGRect
    let collapsedNotchFrame: CGRect
}

struct NotchStatusOverlayMenuEntry {
    enum Kind {
        case item
        case header
        case separator
    }

    let kind: Kind
    let primaryText: String
    let secondaryText: String?
    let identifier: String?
    let indicatorImage: NSImage?
    let projectIndex: Int?
    let indentationLevel: Int
    let isEnabled: Bool
    let onSelect: (() -> Void)?

    static func item(
        primaryText: String,
        secondaryText: String? = nil,
        identifier: String? = nil,
        indicatorImage: NSImage? = nil,
        projectIndex: Int? = nil,
        indentationLevel: Int = 0,
        isEnabled: Bool = true,
        onSelect: (() -> Void)? = nil
    ) -> NotchStatusOverlayMenuEntry {
        NotchStatusOverlayMenuEntry(
            kind: .item,
            primaryText: primaryText,
            secondaryText: secondaryText,
            identifier: identifier,
            indicatorImage: indicatorImage,
            projectIndex: projectIndex,
            indentationLevel: indentationLevel,
            isEnabled: isEnabled,
            onSelect: onSelect
        )
    }

    static func header(_ text: String) -> NotchStatusOverlayMenuEntry {
        NotchStatusOverlayMenuEntry(
            kind: .header,
            primaryText: text,
            secondaryText: nil,
            identifier: nil,
            indicatorImage: nil,
            projectIndex: nil,
            indentationLevel: 0,
            isEnabled: false,
            onSelect: nil
        )
    }

    static func separator() -> NotchStatusOverlayMenuEntry {
        NotchStatusOverlayMenuEntry(
            kind: .separator,
            primaryText: "",
            secondaryText: nil,
            identifier: nil,
            indicatorImage: nil,
            projectIndex: nil,
            indentationLevel: 0,
            isEnabled: false,
            onSelect: nil
        )
    }
}

private func clamp01(_ value: CGFloat) -> CGFloat {
    min(max(value, 0), 1)
}

private func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
    start + ((end - start) * progress)
}

private func interpolate(_ start: CGRect, _ end: CGRect, progress: CGFloat) -> CGRect {
    CGRect(
        x: interpolate(start.minX, end.minX, progress: progress),
        y: interpolate(start.minY, end.minY, progress: progress),
        width: interpolate(start.width, end.width, progress: progress),
        height: interpolate(start.height, end.height, progress: progress)
    )
}

private func scaledRect(_ rect: CGRect, scaleX: CGFloat, scaleY: CGFloat, yOffset: CGFloat = 0) -> CGRect {
    let width = rect.width * scaleX
    let height = rect.height * scaleY
    return CGRect(
        x: rect.midX - (width / 2),
        y: rect.midY - (height / 2) + yOffset,
        width: width,
        height: height
    )
}

@MainActor
private final class NotchMotionAnimator {
    private var timer: Timer?
    private var startTime: TimeInterval = 0
    private var fromValue: CGFloat = 0
    private var toValue: CGFloat = 0
    private var duration: TimeInterval = 0
    private var update: ((CGFloat) -> Void)?
    private var completion: (() -> Void)?

    func animate(
        from: CGFloat,
        to: CGFloat,
        duration: TimeInterval,
        update: @escaping (CGFloat) -> Void,
        completion: (() -> Void)? = nil
    ) {
        stop()

        guard abs(from - to) > 0.001 else {
            update(to)
            completion?()
            return
        }

        self.fromValue = from
        self.toValue = to
        self.duration = duration
        self.update = update
        self.completion = completion
        startTime = ProcessInfo.processInfo.systemUptime
        update(from)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        update = nil
        completion = nil
    }

    private func tick() {
        guard let update else {
            stop()
            return
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let rawProgress = duration > 0 ? elapsed / duration : 1
        let progress = clamp01(rawProgress)
        let easedProgress = easeInOutCubic(progress)
        let currentValue = interpolate(fromValue, toValue, progress: easedProgress)
        update(currentValue)

        if progress >= 1 {
            let completion = self.completion
            stop()
            completion?()
        }
    }

    private func easeInOutCubic(_ value: CGFloat) -> CGFloat {
        if value < 0.5 {
            return 4 * value * value * value
        }

        let adjusted = (-2 * value) + 2
        return 1 - ((adjusted * adjusted * adjusted) / 2)
    }
}

@MainActor
final class NotchStatusOverlayController {
    enum Metrics {
        static let collapsedPanelHeight: CGFloat = 220
        static let expandedPanelHeight: CGFloat = 520
        static let panelWidth: CGFloat = 520
        static let expandedSurfaceWidth: CGFloat = 460
        static let virtualNotchWidthExpansion: CGFloat = 108
        static let spritePointSize = NSSize(width: 34, height: 34)
        static let compactSpritePointSize = NSSize(width: 56, height: 56)
    }

    private enum Motion {
        static let menuOpenDuration: TimeInterval = 0.24
        static let menuCloseDuration: TimeInterval = 0.2
        static let hoverDuration: TimeInterval = 0.18
    }

    private let panel = NotchStatusPanel(frame: .zero)
    private let overlayView = NotchStatusOverlayView(frame: .zero)
    private let menuAnimator = NotchMotionAnimator()
    private let hoverAnimator = NotchMotionAnimator()
    private(set) var isMenuExpanded = false
    private var menuExpansionProgress: CGFloat = 0
    private var hoverProgress: CGFloat = 0
    private var currentScreen: NSScreen?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var isActivationHovered = false
    var onActivate: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)? {
        didSet {
            overlayView.onKeyDown = onKeyDown
        }
    }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = overlayView
        installPointerMonitors()
    }

    func show(on screen: NSScreen) {
        currentScreen = screen
        DebugTraceLogger.log("overlay show screen=\(screen.localizedName) expanded=\(isMenuExpanded)")
        applyOverlayState()
        panel.orderFrontRegardless()
    }

    func hide() {
        DebugTraceLogger.log("overlay hide expanded=\(isMenuExpanded)")
        menuAnimator.stop()
        hoverAnimator.stop()
        isMenuExpanded = false
        menuExpansionProgress = 0
        hoverProgress = 0
        overlayView.menuExpansionProgress = 0
        overlayView.hoverProgress = 0
        setActivationHovered(false)
        panel.orderOut(nil)
    }

    func update(
        spriteImage: NSImage?,
        statusSprite: MenubarStatusPresentation.StatusSprite,
        statusText: String,
        frameIndex: Int,
        hasNotch: Bool
    ) {
        overlayView.spriteImage = spriteImage
        overlayView.statusSprite = statusSprite
        overlayView.statusText = statusText
        overlayView.frameIndex = frameIndex
        overlayView.usesCompactLayout = !hasNotch
        overlayView.spritePointSize = hasNotch ? Metrics.spritePointSize : Metrics.compactSpritePointSize
        currentScreen = panel.screen ?? currentScreen

        if panel.isVisible {
            applyOverlayState()
        }
    }

    func setMenuItems(_ menuItems: [NotchStatusOverlayMenuEntry]) {
        DebugTraceLogger.log("overlay setMenuItems count=\(menuItems.count)")
        overlayView.setMenuItems(menuItems)
    }

    func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        overlayView.handleKeyboardEvent(event)
    }

    func flashMenuItem(identifier: String) {
        overlayView.flashMenuItem(identifier: identifier)
    }

    func handleExpandedMenuKeyEvent(_ event: NSEvent) -> Bool {
        guard isMenuExpanded else {
            return false
        }

        return overlayView.handleMenuNavigationKeyDown(event)
    }

    func moveExpandedMenuSelectionByProject(_ delta: Int) -> Bool {
        guard isMenuExpanded else {
            return false
        }

        return overlayView.moveKeyboardSelectionByProject(delta)
    }

    func showMenu(on screen: NSScreen) {
        currentScreen = screen
        isMenuExpanded = true
        DebugTraceLogger.log("overlay showMenu screen=\(screen.localizedName)")
        animateHover(to: 0)
        show(on: screen)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(overlayView)
        overlayView.prepareForMenuOpen()
        animateMenuExpansion(to: 1)
    }

    func hideMenu() {
        guard isMenuExpanded || menuExpansionProgress > 0.001 else {
            return
        }

        DebugTraceLogger.log("overlay hideMenu progress=\(String(format: "%.3f", menuExpansionProgress))")
        isMenuExpanded = false
        animateMenuExpansion(to: 0)
    }

    func containsExpandedMenu(screenPoint: NSPoint) -> Bool {
        guard menuExpansionProgress > 0.08 else {
            return false
        }

        let interactiveFrame = overlayView.interactiveFrame
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        return interactiveFrame.contains(screenPoint)
    }

    private func installPointerMonitors() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else {
            return
        }

        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            self?.handlePointerEvent(event.locationInWindow, type: event.type, sourceWindow: event.window)
            return event
        }

        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handlePointerEvent(event.locationInWindow, type: event.type, sourceWindow: nil)
            }
        }
    }

    private func handlePointerEvent(_ eventLocation: NSPoint, type: NSEvent.EventType, sourceWindow: NSWindow?) {
        guard panel.isVisible else {
            return
        }

        let screenPoint: NSPoint
        if let sourceWindow {
            screenPoint = sourceWindow.convertToScreen(CGRect(origin: eventLocation, size: .zero)).origin
        } else {
            screenPoint = eventLocation
        }

        switch type {
        case .mouseMoved:
            updateCollapsedHoverState(screenPoint: screenPoint)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            updateCollapsedHoverState(screenPoint: screenPoint)
            guard menuExpansionProgress < 0.02 else {
                return
            }
            if collapsedActivationFrame.contains(screenPoint) {
                DebugTraceLogger.log("overlay activation click point=\(Int(screenPoint.x)),\(Int(screenPoint.y))")
                onActivate?()
            }
        default:
            break
        }
    }

    private func updateCollapsedHoverState(screenPoint: NSPoint) {
        guard menuExpansionProgress < 0.02 else {
            setActivationHovered(false)
            return
        }

        setActivationHovered(collapsedActivationFrame.contains(screenPoint))
    }

    private var collapsedActivationFrame: CGRect {
        overlayView.activationFrame
            .offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    private func setActivationHovered(_ isHovered: Bool) {
        guard isActivationHovered != isHovered else {
            return
        }

        isActivationHovered = isHovered
        if isHovered {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }

        guard menuExpansionProgress < 0.02 else {
            return
        }

        animateHover(to: isHovered ? 1 : 0)
    }

    private func animateHover(to target: CGFloat) {
        hoverAnimator.animate(
            from: hoverProgress,
            to: target,
            duration: Motion.hoverDuration
        ) { [weak self] value in
            guard let self else { return }
            self.hoverProgress = value
            self.applyOverlayState()
        }
    }

    private func animateMenuExpansion(to target: CGFloat) {
        menuAnimator.animate(
            from: menuExpansionProgress,
            to: target,
            duration: target > menuExpansionProgress ? Motion.menuOpenDuration : Motion.menuCloseDuration
        ) { [weak self] value in
            guard let self else { return }
            self.menuExpansionProgress = value
            self.applyOverlayState()
        }
    }

    private func applyOverlayState() {
        guard let screen = currentScreen ?? panel.screen ?? NSScreen.main else {
            return
        }

        let geometry = screen.notchStatusOverlayGeometry(panelHeight: Metrics.expandedPanelHeight)
        if panel.frame != geometry.panelFrame {
            panel.setFrame(geometry.panelFrame, display: false)
        }

        overlayView.geometry = geometry
        overlayView.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        overlayView.menuExpansionProgress = menuExpansionProgress
        overlayView.hoverProgress = hoverProgress
        panel.ignoresMouseEvents = menuExpansionProgress < 0.98
        overlayView.needsLayout = true
        overlayView.needsDisplay = true

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        updateCollapsedHoverState(screenPoint: NSEvent.mouseLocation)
    }
}

final class NotchStatusPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        appearance = NSAppearance(named: .darkAqua)
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchMenuSeparatorView: NSView {
    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let lineRect = CGRect(
            x: 0,
            y: floor(bounds.midY),
            width: bounds.width,
            height: 1
        )
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        NSBezierPath(rect: lineRect).fill()
    }
}

private class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private final class NotchMenuDocumentView: FlippedDocumentView {
    var rowHitTest: ((NSPoint) -> NSView?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let rowHitTest, let rowView = rowHitTest(point) {
            return rowView
        }

        return super.hitTest(point)
    }
}

private final class LockedHorizontalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }
}

private final class NotchMenuScrollView: NSScrollView {
    var onManualScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onManualScroll?()
        super.scrollWheel(with: event)
    }
}

final class NotchStatusOverlayView: NSView {
    private enum Layout {
        static let notchSpriteOffsetFromHardwareNotch: CGFloat = 12
        static let notchSpriteTrailingInset: CGFloat = 18
        static let notchSpriteBottomInset: CGFloat = 1
        static let expandedMenuSpriteHorizontalShift: CGFloat = 16
        static let notchTopCornerRadius: CGFloat = 6
        static let notchBottomCornerRadius: CGFloat = 14
        static let expandedNotchTopCornerRadius: CGFloat = 19
        static let expandedNotchBottomCornerRadius: CGFloat = 24
        static let compactIslandHeight: CGFloat = 84
        static let compactIslandTopInset: CGFloat = 8
        static let compactIslandWidth: CGFloat = 156
        static let compactShadowHeight: CGFloat = 18
        static let labelHeight: CGFloat = 14
        static let expandedPanelBottomInset: CGFloat = 8
        static let expandedPanelCornerRadius: CGFloat = 22
        static let expandedHeaderHeight: CGFloat = 40
        static let expandedHeaderBottomSpacing: CGFloat = 0
        static let expandedContentHorizontalInset: CGFloat = 18
        static let expandedContentBottomInset: CGFloat = 14
        static let expandedSpriteSize = NSSize(width: 34, height: 34)
        static let expandedCompactSpriteSize = NSSize(width: 40, height: 40)
        static let menuRowHeight: CGFloat = 22
        static let menuHeaderHeight: CGFloat = 16
        static let menuSeparatorHeight: CGFloat = 13
        static let menuRowSpacing: CGFloat = 4
        static let menuRowLeadingInset: CGFloat = 16
        static let menuRowTrailingInset: CGFloat = 24
        static let menuSeparatorLeadingInset: CGFloat = 24
        static let menuSeparatorTrailingInset: CGFloat = 32
    }

    private let imageView = NSImageView()
    private let menuScrollView = NotchMenuScrollView()
    private let menuDocumentView = NotchMenuDocumentView()
    private let surfaceMaskLayer = CAShapeLayer()
    private var menuRows: [MenuRowRecord] = []
    private var selectedMenuRowIndex: Int?
    private var usesContextualSelectionAnchor = false
    private var flashedMenuIdentifier: String?
    private var highlightResetWorkItem: DispatchWorkItem?
    private var lastLaidOutMenuContentWidth: CGFloat = -1
    fileprivate var geometry: NotchStatusOverlayGeometry?
    var onKeyDown: ((NSEvent) -> Bool)?

    private enum MenuRowKind {
        case item
        case header
        case separator
    }

    private struct MenuRowRecord {
        let view: NSView
        let kind: MenuRowKind
        let identifier: String?
        let selectionKey: String?
        let projectIndex: Int?
        let isEnabled: Bool
    }

    var spriteImage: NSImage? {
        didSet { imageView.image = spriteImage }
    }

    var statusText = "" {
        didSet {
            needsDisplay = true
        }
    }

    var statusSprite: MenubarStatusPresentation.StatusSprite = .idle {
        didSet { needsLayout = true }
    }

    var frameIndex = 0 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var usesCompactLayout = false {
        didSet {
            syncMenuBackgrounds()
            lastLaidOutMenuContentWidth = -1
            needsLayout = true
            needsDisplay = true
        }
    }

    var spritePointSize = NSSize(width: 64, height: 64) {
        didSet { needsLayout = true }
    }

    var menuExpansionProgress: CGFloat = 0 {
        didSet {
            let revealProgress = expandedRevealProgress
            menuScrollView.isHidden = revealProgress < 0.01
            menuScrollView.alphaValue = revealProgress
            needsLayout = true
            needsDisplay = true
        }
    }

    var hoverProgress: CGFloat = 0 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }

    var interactiveFrame: CGRect {
        guard menuExpansionProgress > 0.08 else {
            return .zero
        }

        return surfaceInteractiveFrame
    }

    var activationFrame: CGRect {
        if usesCompactLayout {
            return compactIslandFrame.insetBy(dx: -8, dy: -6)
        }

        return collapsedNotchFrame
            .union(imageView.frame.insetBy(dx: -8, dy: -8))
            .insetBy(dx: -6, dy: -4)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = surfaceMaskLayer

        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        imageView.layer?.minificationFilter = .nearest
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        menuScrollView.drawsBackground = true
        menuScrollView.borderType = .noBorder
        menuScrollView.hasVerticalScroller = true
        menuScrollView.hasHorizontalScroller = false
        menuScrollView.autohidesScrollers = true
        menuScrollView.horizontalScrollElasticity = .none
        menuScrollView.verticalScroller?.controlSize = .small
        menuScrollView.backgroundColor = .black
        menuScrollView.contentView = LockedHorizontalClipView()
        menuScrollView.contentView.wantsLayer = true
        menuScrollView.contentView.layer?.backgroundColor = NSColor.black.cgColor
        menuScrollView.documentView = menuDocumentView
        menuScrollView.isHidden = true
        menuScrollView.onManualScroll = { [weak self] in
            self?.clearKeyboardSelectionForManualScroll()
        }
        addSubview(menuScrollView)

        menuDocumentView.wantsLayer = true
        menuDocumentView.layer?.backgroundColor = NSColor.black.cgColor
        menuDocumentView.rowHitTest = { [weak self] point in
            self?.rowView(at: point)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        if onKeyDown?(event) == true {
            return true
        }

        return handleMenuNavigationKeyDown(event)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyboardEvent(event) {
            return
        }

        super.keyDown(with: event)
    }

    func setMenuItems(_ menuItems: [NotchStatusOverlayMenuEntry]) {
        rebuildMenuRows(menuItems)
    }

    private func syncMenuBackgrounds() {
        let color = NSColor.black
        layer?.backgroundColor = color.cgColor
        menuScrollView.backgroundColor = color
        menuScrollView.contentView.layer?.backgroundColor = color.cgColor
        menuDocumentView.layer?.backgroundColor = color.cgColor
    }

    func flashMenuItem(identifier: String) {
        guard let rowView = menuRows.first(where: { $0.identifier == identifier })?.view as? ThreadDropdownMenuRowView else {
            return
        }

        highlightResetWorkItem?.cancel()
        flashedMenuIdentifier = identifier
        applyRowHighlights()
        scrollRowIntoView(rowView)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.flashedMenuIdentifier == identifier {
                self.flashedMenuIdentifier = nil
            }
            self.applyRowHighlights()
        }
        highlightResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    func prepareForMenuOpen() {
        usesContextualSelectionAnchor = false
        setSelectedMenuRowIndex(nextSelectableMenuRowIndex(from: nil, delta: 1))
        menuScrollView.contentView.scroll(to: .zero)
        menuScrollView.reflectScrolledClipView(menuScrollView.contentView)
        DebugTraceLogger.log(
            "overlay prepareForMenuOpen origin=\(debugPoint(menuScrollView.contentView.bounds.origin)) documentHeight=\(Int(menuDocumentView.frame.height))"
        )
    }

    private var expandedRevealProgress: CGFloat {
        clamp01((menuExpansionProgress - 0.2) / 0.8)
    }

    private var islandEmphasisProgress: CGFloat {
        hoverProgress
    }

    override func layout() {
        super.layout()

        let bobOffset = bobOffsets[frameIndex % bobOffsets.count]
        let collapsedFrame = collapsedSpriteFrame(bobOffset: bobOffset)
        imageView.frame = collapsedFrame

        let contentFrame = expandedContentFrame
        menuScrollView.frame = contentFrame
        let menuLayoutWidth = expandedMenuLayoutFrame.width
        if abs(menuLayoutWidth - lastLaidOutMenuContentWidth) > 0.5 {
            layoutMenuRows(contentWidth: menuLayoutWidth)
            lastLaidOutMenuContentWidth = menuLayoutWidth
        }
        updateSurfaceMask()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !bounds.isEmpty else {
            return
        }

        drawSurface()

        if usesCompactLayout {
            let islandFrame = compactIslandFrame
            NSColor(calibratedRed: 0.24, green: 0.76, blue: 0.99, alpha: 0.14 + (islandEmphasisProgress * 0.1)).setFill()
            let baseFrame = CGRect(
                x: islandFrame.minX + 18,
                y: islandFrame.minY + 6,
                width: islandFrame.width - 36,
                height: Layout.compactShadowHeight
            )
            NSBezierPath(roundedRect: baseFrame, xRadius: 8, yRadius: 8).fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.72 * (1 - expandedRevealProgress)),
                .paragraphStyle: paragraph,
            ]
            let textFrame = CGRect(
                x: islandFrame.minX,
                y: islandFrame.minY - Layout.labelHeight - 3,
                width: islandFrame.width,
                height: Layout.labelHeight
            )
            (statusText as NSString).draw(in: textFrame, withAttributes: attributes)
        }
    }

    private func rebuildMenuRows(_ menuItems: [NotchStatusOverlayMenuEntry]) {
        let summary = menuItems.map { item -> String in
            switch item.kind {
            case .separator:
                return "separator"
            case .header:
                return "header:\(item.primaryText)"
            case .item:
                return "item:\(item.primaryText)"
            }
        }.joined(separator: ", ")
        DebugTraceLogger.log("overlay rebuildMenuRows count=\(menuItems.count) entries=[\(summary)]")

        let previouslySelectedSelectionKey = selectedMenuSelectionKey
        menuRows.forEach { $0.view.removeFromSuperview() }
        menuRows.removeAll()
        selectedMenuRowIndex = nil
        usesContextualSelectionAnchor = false
        flashedMenuIdentifier = nil
        lastLaidOutMenuContentWidth = -1
        highlightResetWorkItem?.cancel()
        highlightResetWorkItem = nil

        for item in menuItems {
            switch item.kind {
            case .separator:
                let separatorView = NotchMenuSeparatorView(frame: .zero)
                menuDocumentView.addSubview(separatorView)
                menuRows.append(
                    MenuRowRecord(
                        view: separatorView,
                        kind: .separator,
                        identifier: nil,
                        selectionKey: nil,
                        projectIndex: nil,
                        isEnabled: false
                    )
                )
            case .header:
                let label = NSTextField(labelWithString: item.primaryText)
                label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
                label.textColor = NSColor(calibratedWhite: 1, alpha: 0.58)
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                menuDocumentView.addSubview(label)
                menuRows.append(
                    MenuRowRecord(
                        view: label,
                        kind: .header,
                        identifier: nil,
                        selectionKey: nil,
                        projectIndex: nil,
                        isEnabled: false
                    )
                )
            case .item:
                let rowView = ThreadDropdownMenuRowView(frame: .zero)
                rowView.configure(
                    title: item.primaryText,
                    secondaryText: item.secondaryText,
                    indicatorImage: item.indicatorImage,
                    indentationLevel: item.indentationLevel,
                    isExpandable: false,
                    isExpanded: false,
                    onOpen: {
                        guard item.isEnabled else { return }
                        DebugTraceLogger.log(
                            "overlay row dispatch title=\(item.primaryText) secondary=\(item.secondaryText ?? "-") scrollOrigin=\(self.debugPoint(self.menuScrollView.contentView.bounds.origin))"
                        )
                        DispatchQueue.main.async {
                            DebugTraceLogger.log("overlay row execute title=\(item.primaryText) secondary=\(item.secondaryText ?? "-")")
                            item.onSelect?()
                        }
                    },
                    onToggle: nil
                )
                rowView.onScrollWheel = { [weak self] in
                    self?.clearKeyboardSelectionForManualScroll()
                }
                rowView.alphaValue = item.isEnabled ? 1 : 0.45
                menuDocumentView.addSubview(rowView)
                menuRows.append(
                    MenuRowRecord(
                        view: rowView,
                        kind: .item,
                        identifier: item.identifier,
                        selectionKey: item.identifier.map { "id:\($0)" } ?? "title:\(item.primaryText)",
                        projectIndex: item.projectIndex,
                        isEnabled: item.isEnabled
                    )
                )
            }
        }

        restoreSelectedMenuRow(selectionKey: previouslySelectedSelectionKey)
        applyRowHighlights()
        needsLayout = true
    }

    private func layoutMenuRows(contentWidth: CGFloat) {
        let width = max(0, contentWidth)
        let itemWidth = max(0, width - Layout.menuRowLeadingInset - Layout.menuRowTrailingInset)
        let separatorWidth = max(0, width - Layout.menuSeparatorLeadingInset - Layout.menuSeparatorTrailingInset)
        var y: CGFloat = 0

        for (index, row) in menuRows.enumerated() {
            switch row.kind {
            case .item:
                row.view.frame = CGRect(
                    x: Layout.menuRowLeadingInset,
                    y: y,
                    width: itemWidth,
                    height: Layout.menuRowHeight
                )
                y += Layout.menuRowHeight
            case .header:
                row.view.frame = CGRect(
                    x: Layout.menuRowLeadingInset,
                    y: y + 1,
                    width: itemWidth,
                    height: Layout.menuHeaderHeight
                )
                y += Layout.menuHeaderHeight
            case .separator:
                row.view.frame = CGRect(
                    x: Layout.menuSeparatorLeadingInset,
                    y: y + 6,
                    width: separatorWidth,
                    height: 1
                )
                y += Layout.menuSeparatorHeight
            }

            if index < menuRows.count - 1 {
                y += Layout.menuRowSpacing
            }
        }

        menuDocumentView.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: max(1, y)
        )
        if selectedMenuRowIndex != nil {
            scrollSelectedMenuRowIntoView()
        }
    }

    private func debugPoint(_ point: CGPoint) -> String {
        "\(Int(point.x)),\(Int(point.y))"
    }

    private func rowView(at point: NSPoint) -> NSView? {
        for row in menuRows.reversed() {
            guard row.kind == .item, row.view.frame.contains(point) else {
                continue
            }

            let convertedPoint = row.view.convert(point, from: menuDocumentView)
            return row.view.hitTest(convertedPoint) ?? row.view
        }

        return nil
    }

    func handleMenuNavigationKeyDown(_ event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        if modifierFlags == .option {
            switch event.keyCode {
            case 125:
                return moveKeyboardSelectionByProject(1)
            case 126:
                return moveKeyboardSelectionByProject(-1)
            default:
                return false
            }
        }

        guard modifierFlags.isEmpty else {
            return false
        }

        switch event.keyCode {
        case 125:
            return moveKeyboardSelection(by: 1)
        case 126:
            return moveKeyboardSelection(by: -1)
        case 36, 76:
            return activateSelectedMenuRow()
        default:
            return false
        }
    }

    private func moveKeyboardSelection(by delta: Int) -> Bool {
        guard let nextIndex = nextSelectableMenuRowIndex(from: selectedMenuRowIndex, delta: delta) else {
            return false
        }

        setSelectedMenuRowIndex(nextIndex)
        return true
    }

    func moveKeyboardSelectionByProject(_ delta: Int) -> Bool {
        guard let nextIndex = nextProjectSelectableMenuRowIndex(from: selectedMenuRowIndex, delta: delta) else {
            return false
        }

        setSelectedMenuRowIndex(nextIndex)
        return true
    }

    private func activateSelectedMenuRow() -> Bool {
        guard let selectedMenuRowIndex,
              menuRows.indices.contains(selectedMenuRowIndex),
              let rowView = menuRows[selectedMenuRowIndex].view as? ThreadDropdownMenuRowView else {
            return false
        }

        guard let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: rowView.bounds.midX, y: rowView.bounds.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: rowView.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }

        rowView.mouseUp(with: event)
        return true
    }

    private func nextSelectableMenuRowIndex(from currentIndex: Int?, delta: Int) -> Int? {
        let selectableIndices = menuRows.indices.filter { menuRows[$0].kind == .item && menuRows[$0].isEnabled }
        guard !selectableIndices.isEmpty else {
            return nil
        }

        if let currentIndex,
           let currentPosition = selectableIndices.firstIndex(of: currentIndex) {
            let nextPosition = (currentPosition + delta + selectableIndices.count) % selectableIndices.count
            return selectableIndices[nextPosition]
        }

        if let currentIndex = contextualSelectionAnchorIndex(delta: delta, selectableIndices: selectableIndices),
           let currentPosition = selectableIndices.firstIndex(of: currentIndex) {
            let nextPosition = (currentPosition + delta + selectableIndices.count) % selectableIndices.count
            return selectableIndices[nextPosition]
        }

        return delta > 0 ? selectableIndices.first : selectableIndices.last
    }

    private func nextProjectSelectableMenuRowIndex(from currentIndex: Int?, delta: Int) -> Int? {
        var firstSelectableIndexByProject: [Int: Int] = [:]
        var orderedProjectIndices: [Int] = []

        for (index, row) in menuRows.enumerated() {
            guard row.kind == .item,
                  row.isEnabled,
                  let projectIndex = row.projectIndex,
                  firstSelectableIndexByProject[projectIndex] == nil else {
                continue
            }

            firstSelectableIndexByProject[projectIndex] = index
            orderedProjectIndices.append(projectIndex)
        }

        guard !orderedProjectIndices.isEmpty else {
            return nil
        }

        let selectableIndices = menuRows.indices.filter { menuRows[$0].kind == .item && menuRows[$0].isEnabled }
        if let currentIndex,
           menuRows.indices.contains(currentIndex),
           let currentProjectIndex = menuRows[currentIndex].projectIndex,
           let currentPosition = orderedProjectIndices.firstIndex(of: currentProjectIndex) {
            let nextPosition = (currentPosition + delta + orderedProjectIndices.count) % orderedProjectIndices.count
            return firstSelectableIndexByProject[orderedProjectIndices[nextPosition]]
        }

        if let currentIndex = contextualSelectionAnchorIndex(delta: delta, selectableIndices: selectableIndices),
           menuRows.indices.contains(currentIndex),
           let currentProjectIndex = menuRows[currentIndex].projectIndex,
           let currentPosition = orderedProjectIndices.firstIndex(of: currentProjectIndex) {
            let nextPosition = (currentPosition + delta + orderedProjectIndices.count) % orderedProjectIndices.count
            return firstSelectableIndexByProject[orderedProjectIndices[nextPosition]]
        }

        let boundaryPosition = delta > 0 ? 0 : orderedProjectIndices.count - 1
        return firstSelectableIndexByProject[orderedProjectIndices[boundaryPosition]]
    }

    private func contextualSelectionAnchorIndex(delta: Int, selectableIndices: [Int]) -> Int? {
        guard usesContextualSelectionAnchor else {
            return nil
        }

        return selectableMenuRowIndexUnderPointer(selectableIndices: selectableIndices)
            ?? visibleSelectableMenuRowIndex(delta: delta, selectableIndices: selectableIndices)
    }

    private func selectableMenuRowIndexUnderPointer(selectableIndices: [Int]) -> Int? {
        guard let window else {
            return nil
        }

        let documentPoint = menuDocumentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visibleRect = menuDocumentView.visibleRect
        guard visibleRect.contains(documentPoint) else {
            return nil
        }

        return selectableIndices.first(where: { menuRows[$0].view.frame.contains(documentPoint) })
    }

    private func visibleSelectableMenuRowIndex(delta: Int, selectableIndices: [Int]) -> Int? {
        let visibleRect = menuDocumentView.visibleRect
        let visibleSelectableIndices = selectableIndices.filter {
            menuRows[$0].view.frame.intersects(visibleRect)
        }

        if !visibleSelectableIndices.isEmpty {
            return delta > 0 ? visibleSelectableIndices.first : visibleSelectableIndices.last
        }

        return delta > 0 ? selectableIndices.first : selectableIndices.last
    }

    private func setSelectedMenuRowIndex(_ index: Int?) {
        selectedMenuRowIndex = index
        if index != nil {
            usesContextualSelectionAnchor = false
        }
        applyRowHighlights()
        scrollSelectedMenuRowIntoView()
    }

    private func clearKeyboardSelectionForManualScroll() {
        guard selectedMenuRowIndex != nil else {
            return
        }

        selectedMenuRowIndex = nil
        usesContextualSelectionAnchor = true
        applyRowHighlights()
    }

    private var selectedMenuSelectionKey: String? {
        guard let selectedMenuRowIndex,
              menuRows.indices.contains(selectedMenuRowIndex) else {
            return nil
        }

        return menuRows[selectedMenuRowIndex].selectionKey
    }

    private func restoreSelectedMenuRow(selectionKey: String?) {
        guard let selectionKey,
              let nextIndex = menuRows.firstIndex(where: {
                  $0.kind == .item && $0.isEnabled && $0.selectionKey == selectionKey
              }) else {
            return
        }

        selectedMenuRowIndex = nextIndex
        usesContextualSelectionAnchor = false
    }

    private func scrollSelectedMenuRowIntoView() {
        guard let selectedMenuRowIndex,
              menuRows.indices.contains(selectedMenuRowIndex),
              let rowView = menuRows[selectedMenuRowIndex].view as? ThreadDropdownMenuRowView else {
            return
        }

        scrollMenuRectIntoView(targetScrollRectForSelectedMenuRow(at: selectedMenuRowIndex, rowView: rowView))
    }

    private func scrollRowIntoView(_ rowView: NSView) {
        scrollMenuRectIntoView(rowView.frame.insetBy(dx: 0, dy: -6))
    }

    private func targetScrollRectForSelectedMenuRow(at index: Int, rowView: NSView) -> CGRect {
        let rowRect = rowView.frame.insetBy(dx: 0, dy: -6)
        guard let headerView = sectionHeaderViewForFirstItem(at: index) else {
            return rowRect
        }

        return rowRect.union(headerView.frame.insetBy(dx: 0, dy: -4))
    }

    private func sectionHeaderViewForFirstItem(at index: Int) -> NSView? {
        guard let previousMenuRowIndex = previousNonSeparatorMenuRowIndex(before: index),
              menuRows[previousMenuRowIndex].kind == .header else {
            return nil
        }

        return menuRows[previousMenuRowIndex].view
    }

    private func previousNonSeparatorMenuRowIndex(before index: Int) -> Int? {
        guard index > 0 else {
            return nil
        }

        for candidateIndex in stride(from: index - 1, through: 0, by: -1) {
            if menuRows[candidateIndex].kind != .separator {
                return candidateIndex
            }
        }

        return nil
    }

    private func scrollMenuRectIntoView(_ rect: CGRect) {
        menuDocumentView.scrollToVisible(rect)
        menuScrollView.reflectScrolledClipView(menuScrollView.contentView)
    }

    private func applyRowHighlights() {
        let suppressHoverHighlights = selectedMenuRowIndex != nil
        for (index, row) in menuRows.enumerated() {
            guard let rowView = row.view as? ThreadDropdownMenuRowView else {
                continue
            }

            rowView.suppressHoverHighlight = suppressHoverHighlights
            let isSelected = selectedMenuRowIndex == index
            let isFlashed = flashedMenuIdentifier != nil && row.identifier == flashedMenuIdentifier
            rowView.isHighlighted = isSelected || isFlashed
        }
    }

    private func updateSurfaceMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceMaskLayer.frame = bounds
        surfaceMaskLayer.path = surfacePath(
            in: surfaceFrame,
            expansionProgress: surfaceExpansionProgress
        )
        CATransaction.commit()
    }

    private func drawSurface() {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let expansionProgress = surfaceExpansionProgress
        let frame = surfaceFrame
        let path = surfacePath(in: frame, expansionProgress: expansionProgress)
        let shadowProgress = max(expansionProgress, islandEmphasisProgress)
        let strokeAlpha = 0.06 + (islandEmphasisProgress * 0.05) + (expansionProgress * 0.05)

        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: usesCompactLayout ? -6 - shadowProgress : -4 - (shadowProgress * 1.5)),
            blur: usesCompactLayout ? 18 + (shadowProgress * 8) : 14 + (shadowProgress * 10),
            color: shadowColor(for: shadowProgress).cgColor
        )
        context.addPath(path)
        context.setFillColor(expandedSurfaceFillColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setFillColor(expandedSurfaceFillColor.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: strokeAlpha).cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

    }

    private func collapsedSpriteFrame(bobOffset: CGFloat) -> CGRect {
        if usesCompactLayout {
            let islandFrame = compactIslandFrame
            let spriteScale = 1 + (islandEmphasisProgress * 0.04)
            let size = NSSize(
                width: spritePointSize.width * spriteScale,
                height: spritePointSize.height * spriteScale
            )
            return CGRect(
                x: islandFrame.midX - (size.width / 2),
                y: islandFrame.minY + 8 + bobOffset + islandEmphasisProgress,
                width: size.width,
                height: size.height
            )
        }

        let islandFrame = collapsedNotchFrame
        let hardwareFrame = hardwareNotchFrame
        let spriteScale = 1 + (islandEmphasisProgress * 0.03)
        let size = NSSize(
            width: spritePointSize.width * spriteScale,
            height: spritePointSize.height * spriteScale
        )
        let collapsedMaxX = islandFrame.maxX - Layout.notchSpriteTrailingInset - size.width
        let expandedMaxX = expandedSurfaceFrame.maxX - Layout.expandedContentHorizontalInset - size.width
        let baseX = min(hardwareFrame.maxX + Layout.notchSpriteOffsetFromHardwareNotch, collapsedMaxX)
        return CGRect(
            x: min(baseX + (menuExpansionProgress * Layout.expandedMenuSpriteHorizontalShift), expandedMaxX),
            y: islandFrame.minY - Layout.notchSpriteBottomInset + bobOffset + islandEmphasisProgress,
            width: size.width,
            height: size.height
        )
    }

    private var compactIslandFrame: CGRect {
        scaledRect(
            compactIslandBaseFrame,
            scaleX: 1 + (islandEmphasisProgress * 0.035),
            scaleY: 1 + (islandEmphasisProgress * 0.12),
            yOffset: islandEmphasisProgress * 2
        )
    }

    private var collapsedNotchFrame: CGRect {
        scaledRect(
            collapsedNotchBaseFrame,
            scaleX: 1 + (islandEmphasisProgress * 0.03),
            scaleY: 1 + (islandEmphasisProgress * 0.16),
            yOffset: islandEmphasisProgress * 1.5
        )
    }

    private var compactIslandBaseFrame: CGRect {
        let width = Layout.compactIslandWidth
        let height = Layout.compactIslandHeight
        return CGRect(
            x: bounds.midX - (width / 2),
            y: bounds.maxY - Layout.compactIslandTopInset - height,
            width: width,
            height: height
        )
    }

    private var collapsedNotchBaseFrame: CGRect {
        geometry?.collapsedNotchFrame ?? fallbackGeometry.collapsedNotchFrame
    }

    private var hardwareNotchFrame: CGRect {
        geometry?.hardwareNotchFrame ?? fallbackGeometry.hardwareNotchFrame
    }

    private var collapsedSurfaceBaseFrame: CGRect {
        usesCompactLayout ? compactIslandBaseFrame : collapsedNotchBaseFrame
    }

    private var expandedSurfaceFrame: CGRect {
        let width = min(
            bounds.width - 20,
            max(
                collapsedSurfaceBaseFrame.width + 140,
                NotchStatusOverlayController.Metrics.expandedSurfaceWidth
            )
        )
        let maxHeight = max(
            Layout.expandedHeaderHeight + Layout.expandedContentBottomInset + 100,
            collapsedSurfaceBaseFrame.maxY - Layout.expandedPanelBottomInset
        )

        return CGRect(
            x: bounds.midX - (width / 2),
            y: Layout.expandedPanelBottomInset,
            width: width,
            height: maxHeight
        )
    }

    private var surfaceExpansionProgress: CGFloat {
        clamp01(menuExpansionProgress)
    }

    private var surfaceFrame: CGRect {
        if surfaceExpansionProgress < 0.001 {
            return usesCompactLayout ? compactIslandFrame : collapsedNotchFrame
        }

        return interpolate(
            collapsedSurfaceBaseFrame,
            expandedSurfaceFrame,
            progress: surfaceExpansionProgress
        )
    }

    private var surfaceInteractiveFrame: CGRect {
        surfaceFrame
    }

    private func expandedHeaderFrame(for frame: CGRect) -> CGRect {
        return CGRect(
            x: frame.minX,
            y: frame.maxY - Layout.expandedHeaderHeight - 12,
            width: frame.width,
            height: Layout.expandedHeaderHeight
        )
    }

    private var expandedHeaderFrame: CGRect {
        expandedHeaderFrame(for: surfaceFrame)
    }

    private func expandedContentFrame(for frame: CGRect) -> CGRect {
        return CGRect(
            x: frame.minX + Layout.expandedContentHorizontalInset,
            y: frame.minY + Layout.expandedContentBottomInset,
            width: frame.width - (Layout.expandedContentHorizontalInset * 2),
            height: max(
                0,
                expandedHeaderFrame(for: frame).minY - frame.minY - Layout.expandedContentBottomInset - Layout.expandedHeaderBottomSpacing
            )
        )
    }

    private var expandedContentFrame: CGRect {
        expandedContentFrame(for: surfaceFrame)
    }

    private var expandedMenuLayoutFrame: CGRect {
        expandedContentFrame(for: expandedSurfaceFrame)
    }

    private var expandedSurfaceFillColor: NSColor {
        .black
    }

    private func surfacePath(in frame: CGRect, expansionProgress: CGFloat) -> CGPath {
        if usesCompactLayout {
            let collapsedRadius = frame.height / 2
            let cornerRadius = interpolate(collapsedRadius, Layout.expandedPanelCornerRadius, progress: expansionProgress)
            return CGPath(
                roundedRect: frame,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
        }

        return notchShapePath(
            in: frame,
            topCornerRadius: interpolate(
                Layout.notchTopCornerRadius,
                Layout.expandedNotchTopCornerRadius,
                progress: expansionProgress
            ),
            bottomCornerRadius: interpolate(
                Layout.notchBottomCornerRadius,
                Layout.expandedNotchBottomCornerRadius,
                progress: expansionProgress
            )
        )
    }

    private func shadowColor(for shadowProgress: CGFloat) -> NSColor {
        if usesCompactLayout {
            return NSColor(
                calibratedRed: 0.08,
                green: 0.18,
                blue: 0.26,
                alpha: 0.22 + (shadowProgress * 0.12)
            )
        }

        return NSColor(
            calibratedRed: 0.07,
            green: 0.17,
            blue: 0.24,
            alpha: 0.16 + (shadowProgress * 0.12)
        )
    }

    private var fallbackGeometry: NotchStatusOverlayGeometry {
        let notchSize = CGSize(width: 185, height: 32)
        let collapsedNotchWidth = notchSize.width + NotchStatusOverlayController.Metrics.virtualNotchWidthExpansion
        let panelWidth = max(
            NotchStatusOverlayController.Metrics.panelWidth,
            collapsedNotchWidth + NotchStatusOverlayController.Metrics.spritePointSize.width + 80
        )
        let panelFrame = CGRect(
            x: 0,
            y: 0,
            width: panelWidth,
            height: NotchStatusOverlayController.Metrics.collapsedPanelHeight
        )
        let hardwareNotchFrame = CGRect(
            x: (panelWidth - notchSize.width) / 2,
            y: panelFrame.height - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
        let collapsedNotchFrame = CGRect(
            x: (panelWidth - collapsedNotchWidth) / 2,
            y: panelFrame.height - notchSize.height,
            width: collapsedNotchWidth,
            height: notchSize.height
        )
        return NotchStatusOverlayGeometry(
            panelFrame: panelFrame,
            hardwareNotchFrame: hardwareNotchFrame,
            collapsedNotchFrame: collapsedNotchFrame
        )
    }

    private var bobOffsets: [CGFloat] {
        [0]
    }

    private func notchShapePath(
        in rect: CGRect,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - topCornerRadius),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + bottomCornerRadius),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - topCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))

        return path
    }
}

extension NSScreen {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    var isBuiltInDisplay: Bool {
        guard let screenNumber = deviceDescription[Self.screenNumberKey] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    var hasCameraHousing: Bool {
        safeAreaInsets.top > 0
    }

    var notchSize: CGSize {
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        guard hasCameraHousing else {
            return CGSize(width: 185, height: max(32, menuBarHeight))
        }

        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0
        let width = fullWidth - leftPadding - rightPadding + 4
        let height = safeAreaInsets.top
        return CGSize(width: width, height: height)
    }

    fileprivate func notchStatusOverlayGeometry(panelHeight: CGFloat) -> NotchStatusOverlayGeometry {
        let notchSize = notchSize
        let notchCenterX = frame.origin.x + (frame.width / 2)
        let collapsedNotchWidth = notchSize.width + NotchStatusOverlayController.Metrics.virtualNotchWidthExpansion
        let panelWidth = max(
            NotchStatusOverlayController.Metrics.panelWidth,
            collapsedNotchWidth + NotchStatusOverlayController.Metrics.spritePointSize.width + 80
        )

        let panelFrame = CGRect(
            x: notchCenterX - (panelWidth / 2),
            y: frame.maxY - panelHeight,
            width: panelWidth,
            height: panelHeight
        )

        let hardwareNotchFrame = CGRect(
            x: notchCenterX - (notchSize.width / 2) - panelFrame.minX,
            y: frame.maxY - notchSize.height - panelFrame.minY,
            width: notchSize.width,
            height: notchSize.height
        )

        let collapsedNotchFrame = CGRect(
            x: notchCenterX - (collapsedNotchWidth / 2) - panelFrame.minX,
            y: frame.maxY - notchSize.height - panelFrame.minY,
            width: collapsedNotchWidth,
            height: notchSize.height
        )

        return NotchStatusOverlayGeometry(
            panelFrame: panelFrame,
            hardwareNotchFrame: hardwareNotchFrame,
            collapsedNotchFrame: collapsedNotchFrame
        )
    }
}
