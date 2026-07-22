import AppKit

@MainActor
final class WeeklyUsageIndicatorView: NSView {
    private enum Metrics {
        static let minimumMenuWidth: CGFloat = 280
        static let height: CGFloat = 52
        static let horizontalPadding: CGFloat = 14
        static let titleY: CGFloat = 6
        static let titleHeight: CGFloat = 18
        static let detailY: CGFloat = 26
        static let detailHeight: CGFloat = 14
        static let textSpacing: CGFloat = 12
        static let barY: CGFloat = 43
        static let barHeight: CGFloat = 4
    }

    private let strings: AppStrings
    private let language: AppLanguage
    private let resetDateFormatter: DateFormatter
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    let remainingPercent: Int?
    let resetsAt: Date?
    let errorMessage: String?

    var titleText: String {
        strings.text("menu.weeklyUsage.title", language: language)
    }

    var valueText: String {
        if errorMessage != nil {
            return strings.text("menu.weeklyUsage.error", language: language)
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
        if let errorMessage {
            return errorMessage
        }

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
        [titleText, valueText, detailText]
            .compactMap { $0 }
            .joined(separator: ", ")
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
        NSSize(width: Metrics.minimumMenuWidth, height: Metrics.height)
    }

    init(
        remainingPercent: Int?,
        resetsAt: Date?,
        errorMessage: String? = nil,
        language: AppLanguage,
        strings: AppStrings = .shared,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.remainingPercent = remainingPercent.map { min(max($0, 0), 100) }
        self.resetsAt = resetsAt
        self.errorMessage = errorMessage
        self.language = language
        self.strings = strings

        let resetDateFormatter = DateFormatter()
        resetDateFormatter.locale = Locale(identifier: language.localeIdentifier)
        resetDateFormatter.timeZone = timeZone
        resetDateFormatter.setLocalizedDateFormatFromTemplate("MMMdhm")
        self.resetDateFormatter = resetDateFormatter

        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("CodexMateWeeklyUsageIndicator")
        autoresizingMask = [.width]

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
            color: errorMessage == nil
                ? (remainingPercent == nil ? .secondaryLabelColor : .labelColor)
                : .systemRed,
            alignment: .right,
            lineBreakMode: .byClipping
        )
        configureLabel(
            detailLabel,
            text: detailText ?? "",
            font: NSFont.systemFont(ofSize: 10.5),
            color: errorMessage == nil ? .secondaryLabelColor : .systemRed,
            alignment: .left,
            lineBreakMode: .byTruncatingTail
        )
        detailLabel.isHidden = detailText == nil

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText)
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

        let contentX = Metrics.horizontalPadding
        let contentWidth = max(0, bounds.width - (Metrics.horizontalPadding * 2))
        let valueWidth = min(contentWidth, ceil(valueLabel.intrinsicContentSize.width))
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
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

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
}
