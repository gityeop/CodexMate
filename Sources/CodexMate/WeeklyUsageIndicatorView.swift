import AppKit

struct WeeklyUsageIndicatorPresentation: Equatable {
    let titleText: String
    let valueText: String
    let detailText: String?
    let remainingPercent: Int?
    /// Several limits shown in one bar, such as Claude's 5-hour and weekly windows.
    var barSegments: [WeeklyUsageBarSegment] = []
}

struct WeeklyUsageBarSegment: Equatable {
    enum Kind: Equatable {
        case fiveHour
        case sevenDay
    }

    let kind: Kind
    let remainingPercent: Int
    let labelText: String
}

@MainActor
final class WeeklyUsageIndicatorView: NSView {
    private enum Metrics {
        static let minimumMenuWidth: CGFloat = 280
        static let height: CGFloat = 56
        static let horizontalPadding: CGFloat = 14
        static let titleY: CGFloat = 10
        static let titleHeight: CGFloat = 18
        static let detailY: CGFloat = 30
        static let detailHeight: CGFloat = 14
        static let textSpacing: CGFloat = 12
        static let valueTrailingPadding: CGFloat = 4
        static let barY: CGFloat = 47
        static let barHeight: CGFloat = 4
        static let additionalRowY: CGFloat = 52
        static let additionalRowHeight: CGFloat = 50
        static let additionalRowHeightIncrement: CGFloat = 46
    }

    private let strings: AppStrings
    private let language: AppLanguage
    private let resetDateFormatter: DateFormatter
    private let pinsToMenu: Bool
    private let errorMessage: String?
    private let claudeUsage: WeeklyUsageIndicatorPresentation?
    private var additionalRowViews: [WeeklyUsageRowView] = []
    private weak var menuTableView: NSTableView?
    private(set) var menuHeaderView: NSView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    let remainingPercent: Int?
    let resetsAt: Date?

    var titleText: String {
        strings.text("menu.weeklyUsage.title", language: language)
    }

    var valueText: String {
        if errorMessage != nil {
            return strings.text("menu.weeklyUsage.unavailable", language: language)
        }

        guard let remainingPercent else {
            return strings.text("menu.weeklyUsage.loading", language: language)
        }

        return strings.format(
            "menu.weeklyUsage.remaining",
            language: language,
            Int64(remainingPercent)
        )
    }

    var detailText: String? {
        guard let resetsAt else {
            return nil
        }

        return strings.format(
            "menu.weeklyUsage.resets",
            language: language,
            resetDateFormatter.string(from: resetsAt)
        )
    }

    var accessibilityText: String {
        let mainParts: [String?] = [titleText, valueText, detailText]
        let additionalParts: [String?] = additionalPresentations.flatMap { presentation -> [String?] in
            [presentation.titleText, presentation.valueText, presentation.detailText]
        }
        return (mainParts + additionalParts)
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Rows shown under the Codex weekly usage, such as Claude's usage limits.
    var additionalPresentations: [WeeklyUsageIndicatorPresentation] {
        claudeUsage.map { [$0] } ?? []
    }

    var presentation: WeeklyUsageIndicatorPresentation {
        WeeklyUsageIndicatorPresentation(
            titleText: titleText,
            valueText: valueText,
            detailText: detailText,
            remainingPercent: remainingPercent
        )
    }

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override var allowsVibrancy: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        // Keep an anchor menu item; the full indicator lives above the menu body.
        NSSize(
            width: Metrics.minimumMenuWidth,
            height: pinsToMenu
                ? 1
                : Metrics.height + CGFloat(additionalPresentations.count) * Metrics.additionalRowHeightIncrement
        )
    }

    init(
        remainingPercent: Int?,
        resetsAt: Date?,
        errorMessage: String? = nil,
        claudeUsage: WeeklyUsageIndicatorPresentation? = nil,
        pinsToMenu: Bool = false,
        language: AppLanguage,
        strings: AppStrings = .shared,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        if errorMessage == nil {
            self.remainingPercent = remainingPercent.map { min(max($0, 0), 100) }
            self.resetsAt = resetsAt
        } else {
            self.remainingPercent = nil
            self.resetsAt = nil
        }
        self.language = language
        self.strings = strings
        self.pinsToMenu = pinsToMenu
        self.errorMessage = errorMessage
        self.claudeUsage = claudeUsage

        let resetDateFormatter = DateFormatter()
        resetDateFormatter.locale = Locale(identifier: language.localeIdentifier)
        resetDateFormatter.timeZone = timeZone
        resetDateFormatter.setLocalizedDateFormatFromTemplate("MMMdhm")
        self.resetDateFormatter = resetDateFormatter

        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("CodexMateWeeklyUsageIndicator")
        autoresizingMask = [.width]

        guard !pinsToMenu else { return }

        configureLabel(
            titleLabel,
            text: titleText,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            valueLabel,
            text: valueText,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: self.remainingPercent == nil ? .secondaryLabelColor : .labelColor,
            alignment: .left,
            lineBreakMode: .byClipping
        )
        configureLabel(
            detailLabel,
            text: detailText ?? "",
            font: NSFont.systemFont(ofSize: 10.5),
            color: .secondaryLabelColor,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        detailLabel.isHidden = detailText == nil

        for presentation in additionalPresentations {
            let rowView = WeeklyUsageRowView(presentation: presentation)
            additionalRowViews.append(rowView)
            addSubview(rowView)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Menu rows leave the table when scrolled offscreen; the header must stay attached.
        guard pinsToMenu, window != nil else { return }
        guard let tableView = enclosingScrollView?.documentView as? NSTableView else {
            DebugTraceLogger.log("Failed to pin weekly usage: menu table view is unavailable.")
            return
        }
        installMenuHeader(in: tableView)
    }

    func updatePinnedMenuHeader(replacing previousView: WeeklyUsageIndicatorView?) {
        guard pinsToMenu,
              let previousView,
              let header = previousView.menuHeaderView as? WeeklyUsageMenuHeaderView else { return }
        menuTableView = previousView.menuTableView
        menuHeaderView = header
        header.updateIndicator(makeHeaderIndicator())
    }

    func revealMenuItem(_ item: NSMenuItem?) {
        guard pinsToMenu, let item else { return }
        let reveal: @MainActor @Sendable () -> Void = { [weak self, weak item] in
            guard let table = self?.menuTableView,
                  let item,
                  let menu = item.menu,
                  menu.highlightedItem === item,
                  let row = menu.items.filter({ !$0.isHidden }).firstIndex(of: item) else { return }
            table.scrollRowToVisible(row)
        }
        // AppKit finishes its own scrolling after willHighlight; then use the reduced viewport.
        RunLoop.main.perform(inModes: [.eventTracking]) {
            MainActor.assumeIsolated { reveal() }
        }
    }

    private func installMenuHeader(in tableView: NSTableView) {
        guard let scrollView = tableView.enclosingScrollView,
              let menuBody = scrollView.superview,
              let container = menuBody.superview else {
            DebugTraceLogger.log("Failed to pin weekly usage: menu container is unavailable.")
            return
        }
        if menuTableView === tableView, menuHeaderView?.superview === container {
            return
        }
        menuHeaderView?.removeFromSuperview()

        let header = WeeklyUsageMenuHeaderView(indicator: makeHeaderIndicator())
        menuTableView = tableView
        menuHeaderView = header
        container.addSubview(header)
        header.reserveSpaceAboveContent(in: scrollView)
    }

    private func makeHeaderIndicator() -> WeeklyUsageIndicatorView {
        WeeklyUsageIndicatorView(
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            errorMessage: errorMessage,
            claudeUsage: claudeUsage,
            language: language,
            strings: strings,
            timeZone: resetDateFormatter.timeZone
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()

        let contentX = Metrics.horizontalPadding
        let contentWidth = max(0, bounds.width - (Metrics.horizontalPadding * 2))
        let valueWidth = min(contentWidth, ceil(valueLabel.intrinsicContentSize.width) + Metrics.valueTrailingPadding)
        let titleWidth = max(0, contentWidth - valueWidth - Metrics.textSpacing)

        titleLabel.frame = NSRect(
            x: contentX,
            y: Metrics.titleY,
            width: titleWidth,
            height: Metrics.titleHeight
        )
        valueLabel.frame = NSRect(
            x: bounds.maxX - Metrics.horizontalPadding - valueWidth,
            y: Metrics.titleY,
            width: valueWidth,
            height: Metrics.titleHeight
        )
        detailLabel.frame = NSRect(
            x: contentX,
            y: Metrics.detailY,
            width: contentWidth,
            height: Metrics.detailHeight
        )

        for (index, rowView) in additionalRowViews.enumerated() {
            rowView.frame = NSRect(
                x: contentX,
                y: Metrics.additionalRowY + CGFloat(index) * Metrics.additionalRowHeightIncrement,
                width: contentWidth,
                height: Metrics.additionalRowHeight
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !pinsToMenu else { return }

        let barRect = CGRect(
            x: Metrics.horizontalPadding,
            y: Metrics.barY,
            width: max(0, bounds.width - (Metrics.horizontalPadding * 2)),
            height: Metrics.barHeight
        )
        drawBar(in: barRect)
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        lineBreakMode: NSLineBreakMode
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.alignment = alignment
        label.cell?.lineBreakMode = lineBreakMode
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }

    private func drawBar(in rect: CGRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(
            roundedRect: rect,
            xRadius: rect.height / 2,
            yRadius: rect.height / 2
        ).fill()

        guard let remainingPercent, remainingPercent > 0 else {
            return
        }

        let proportionalWidth = rect.width * CGFloat(remainingPercent) / 100
        let activeRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: min(rect.width, max(rect.height, proportionalWidth)),
            height: rect.height
        )
        Self.progressColor(for: remainingPercent).setFill()
        NSBezierPath(
            roundedRect: activeRect,
            xRadius: activeRect.height / 2,
            yRadius: activeRect.height / 2
        ).fill()
    }

    static func progressColor(for remainingPercent: Int) -> NSColor {
        switch min(max(remainingPercent, 0), 100) {
        case 50...:
            return .systemGreen
        case 20..<50:
            return .systemOrange
        default:
            return .systemRed
        }
    }

    enum SegmentPolicy {
        static let lowRemainingPercent = 25
        static let criticalRemainingPercent = 10
        static let underlyingSegmentAlpha: CGFloat = 0.55
    }

    /// Each window keeps its own color until it runs low, then shows the warning color.
    static func segmentColor(for segment: WeeklyUsageBarSegment) -> NSColor {
        if segment.remainingPercent < SegmentPolicy.criticalRemainingPercent {
            return .systemRed
        }
        if segment.remainingPercent < SegmentPolicy.lowRemainingPercent {
            return .systemOrange
        }
        switch segment.kind {
        case .fiveHour:
            return .systemBlue
        case .sevenDay:
            return .systemPurple
        }
    }

    /// Draws every segment from the left edge; shorter segments sit on top so each stays visible.
    static func drawSegments(_ segments: [WeeklyUsageBarSegment], in barRect: CGRect) {
        let ordered = segments.sorted { $0.remainingPercent > $1.remainingPercent }
        for (index, segment) in ordered.enumerated() where segment.remainingPercent > 0 {
            let proportionalWidth = barRect.width * CGFloat(min(segment.remainingPercent, 100)) / 100
            let activeRect = CGRect(
                x: barRect.minX,
                y: barRect.minY,
                width: min(barRect.width, max(barRect.height, proportionalWidth)),
                height: barRect.height
            )
            let isUnderlying = index < ordered.count - 1
            segmentColor(for: segment)
                .withAlphaComponent(isUnderlying ? SegmentPolicy.underlyingSegmentAlpha : 1)
                .setFill()
            NSBezierPath(
                roundedRect: activeRect,
                xRadius: activeRect.height / 2,
                yRadius: activeRect.height / 2
            ).fill()
        }
    }

    /// Value text with a colored dot before each segment, so the bar colors read as a legend.
    static func segmentLegend(
        for presentation: WeeklyUsageIndicatorPresentation,
        font: NSFont,
        textColor: NSColor
    ) -> NSAttributedString? {
        guard !presentation.barSegments.isEmpty else {
            return nil
        }

        let legend = NSMutableAttributedString()
        for (index, segment) in presentation.barSegments.enumerated() {
            if index > 0 {
                legend.append(NSAttributedString(string: " · ", attributes: [.font: font, .foregroundColor: textColor]))
            }
            let dotFont = NSFont.systemFont(ofSize: round(font.pointSize * 0.7))
            legend.append(NSAttributedString(
                string: "● ",
                attributes: [
                    .font: dotFont,
                    .foregroundColor: segmentColor(for: segment),
                    .baselineOffset: (font.capHeight - dotFont.capHeight) / 2,
                ]
            ))
            legend.append(NSAttributedString(
                string: segment.labelText,
                attributes: [.font: font, .foregroundColor: textColor]
            ))
        }
        return legend
    }
}

@MainActor
private final class WeeklyUsageMenuHeaderView: NSView {
    private weak var menuBody: NSView?
    private weak var menuScrollView: NSScrollView?
    private var headerHeight: CGFloat
    private var scrollTopInset: CGFloat = 0
    private var scrollBottomInset: CGFloat = 0
    private var isLayingOut = false

    init(indicator: WeeklyUsageIndicatorView) {
        headerHeight = indicator.intrinsicContentSize.height
        super.init(frame: NSRect(origin: .zero, size: indicator.intrinsicContentSize))
        identifier = NSUserInterfaceItemIdentifier("CodexMateWeeklyUsageHeader")
        clipsToBounds = true
        updateIndicator(indicator)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateIndicator(_ indicator: WeeklyUsageIndicatorView) {
        subviews.forEach { $0.removeFromSuperview() }
        let indicatorHeight = indicator.intrinsicContentSize.height
        let heightChanged = indicatorHeight != headerHeight
        headerHeight = indicatorHeight
        indicator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        indicator.autoresizingMask = [.width, .height]
        addSubview(indicator)
        if heightChanged {
            // The Claude row can appear or disappear while the menu is open.
            layoutMenuBody()
        }
    }

    func reserveSpaceAboveContent(in scrollView: NSScrollView) {
        guard let menuBody = scrollView.superview, let container = superview else { return }
        self.menuBody = menuBody
        menuScrollView = scrollView
        updateScrollInsets()
        for view in [menuBody, container] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(layoutMenuBody),
                name: NSView.frameDidChangeNotification,
                object: view
            )
        }
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )
        layoutMenuBody()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutMenuBody()
    }

    @objc private func layoutMenuBody() {
        guard !isLayingOut, window != nil,
              let menuBody,
              let menuScrollView,
              let container = superview else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        // Reserve space above the entire native menu, including its scroll arrows.
        let bounds = container.bounds
        let headerFrame = NSRect(
            x: bounds.minX,
            y: container.isFlipped ? bounds.minY : bounds.maxY - headerHeight,
            width: bounds.width,
            height: headerHeight
        )
        let bodyFrame = NSRect(
            x: bounds.minX,
            y: container.isFlipped ? bounds.minY + headerHeight : bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
        if frame != headerFrame {
            frame = headerFrame
        }
        if menuBody.frame != bodyFrame {
            menuBody.frame = bodyFrame
        }
        let scrollFrame = NSRect(
            x: 0,
            y: menuBody.isFlipped ? scrollTopInset : scrollBottomInset,
            width: bodyFrame.width,
            height: max(0, bodyFrame.height - scrollTopInset - scrollBottomInset)
        )
        if menuScrollView.frame != scrollFrame {
            menuScrollView.frame = scrollFrame
        }
    }

    @objc private func scrollFrameDidChange() {
        guard !isLayingOut else { return }
        updateScrollInsets()
        layoutMenuBody()
    }

    private func updateScrollInsets() {
        guard let menuBody, let menuScrollView, let container = superview else { return }
        let leadingInset = menuScrollView.frame.minY
        let trailingInset = max(0, container.bounds.height - menuScrollView.frame.maxY)
        scrollTopInset = menuBody.isFlipped ? leadingInset : trailingInset
        scrollBottomInset = menuBody.isFlipped ? trailingInset : leadingInset
    }
}

/// One extra usage row (title, value, detail and remaining bar) drawn below the Codex weekly usage.
@MainActor
private final class WeeklyUsageRowView: NSView {
    private enum Metrics {
        static let titleY: CGFloat = 4
        static let titleHeight: CGFloat = 18
        static let detailY: CGFloat = 24
        static let detailHeight: CGFloat = 14
        static let textSpacing: CGFloat = 12
        static let valueTrailingPadding: CGFloat = 4
        static let barY: CGFloat = 41
        static let barHeight: CGFloat = 4
    }

    let presentation: WeeklyUsageIndicatorPresentation
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override var isFlipped: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override var allowsVibrancy: Bool {
        true
    }

    init(presentation: WeeklyUsageIndicatorPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("CodexMateAdditionalUsageRow")

        configureLabel(
            titleLabel,
            text: presentation.titleText,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: .labelColor,
            lineBreakMode: .byTruncatingTail
        )
        configureLabel(
            valueLabel,
            text: presentation.valueText,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            color: presentation.remainingPercent == nil ? .secondaryLabelColor : .labelColor,
            lineBreakMode: .byClipping
        )
        configureLabel(
            detailLabel,
            text: presentation.detailText ?? "",
            font: NSFont.systemFont(ofSize: 10.5),
            color: .secondaryLabelColor,
            lineBreakMode: .byTruncatingTail
        )
        detailLabel.isHidden = presentation.detailText == nil
        if let legend = WeeklyUsageIndicatorView.segmentLegend(
            for: presentation,
            font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            textColor: .labelColor
        ) {
            valueLabel.attributedStringValue = legend
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()

        let contentWidth = max(0, bounds.width)
        let valueWidth = min(contentWidth, ceil(valueLabel.intrinsicContentSize.width) + Metrics.valueTrailingPadding)
        let titleWidth = max(0, contentWidth - valueWidth - Metrics.textSpacing)

        titleLabel.frame = NSRect(x: 0, y: Metrics.titleY, width: titleWidth, height: Metrics.titleHeight)
        valueLabel.frame = NSRect(
            x: bounds.maxX - valueWidth,
            y: Metrics.titleY,
            width: valueWidth,
            height: Metrics.titleHeight
        )
        detailLabel.frame = NSRect(x: 0, y: Metrics.detailY, width: contentWidth, height: Metrics.detailHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barRect = CGRect(x: 0, y: Metrics.barY, width: bounds.width, height: Metrics.barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barRect.height / 2, yRadius: barRect.height / 2).fill()

        if !presentation.barSegments.isEmpty {
            WeeklyUsageIndicatorView.drawSegments(presentation.barSegments, in: barRect)
            return
        }

        guard let remainingPercent = presentation.remainingPercent, remainingPercent > 0 else {
            return
        }

        let proportionalWidth = barRect.width * CGFloat(min(remainingPercent, 100)) / 100
        let activeRect = CGRect(
            x: barRect.minX,
            y: barRect.minY,
            width: min(barRect.width, max(barRect.height, proportionalWidth)),
            height: barRect.height
        )
        WeeklyUsageIndicatorView.progressColor(for: remainingPercent).setFill()
        NSBezierPath(roundedRect: activeRect, xRadius: activeRect.height / 2, yRadius: activeRect.height / 2).fill()
    }

    private func configureLabel(
        _ label: NSTextField,
        text: String,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode
    ) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.alignment = .left
        label.cell?.lineBreakMode = lineBreakMode
        label.cell?.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }
}
