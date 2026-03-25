import AppKit

final class ThreadDropdownMenuRowView: NSView {
    private enum Layout {
        static let rowHeight: CGFloat = 22
        static let horizontalPadding: CGFloat = 8
        static let indentationWidth: CGFloat = 14
        static let disclosureSize: CGFloat = 12
        static let disclosureSpacing: CGFloat = 4
        static let iconSize: CGFloat = 12
        static let iconSpacing: CGFloat = 6
        static let metadataSpacing: CGFloat = 8
        static let minimumWidth: CGFloat = 220
    }

    private static let titleFont = NSFont.systemFont(ofSize: 13)
    private static let hoverFillColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    private static let selectedFillColor = NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.88, alpha: 0.28)

    static func preferredWidth(
        title: String,
        secondaryText: String? = nil,
        indentationLevel: Int,
        isExpandable: Bool
    ) -> CGFloat {
        let titleWidth = ceil(
            NSString(string: title).size(withAttributes: [.font: titleFont]).width
        )
        let secondaryWidth = ceil(
            NSString(string: secondaryText ?? "").size(withAttributes: [.font: titleFont]).width
        )
        let disclosureWidth = isExpandable ? Layout.disclosureSize + Layout.disclosureSpacing : 0
        let indentationWidth = CGFloat(max(0, indentationLevel)) * Layout.indentationWidth
        let iconWidth = Layout.iconSize + Layout.iconSpacing
        let contentWidth = Layout.horizontalPadding * 2
            + indentationWidth
            + disclosureWidth
            + iconWidth
            + titleWidth
            + (secondaryText == nil ? 0 : Layout.metadataSpacing + secondaryWidth)
        let width = ceil(contentWidth)

        return max(Layout.minimumWidth, width)
    }

    private let disclosureButton = NSButton(title: "▸", target: nil, action: nil)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var indentationLevel: Int = 0
    private var isExpandable = false
    private var isHovered = false
    private var debugIdentifier = ""
    private var onOpen: (() -> Void)?
    private var onToggle: (() -> Void)?

    var isHighlighted: Bool = false {
        didSet {
            needsDisplay = true
            updateAppearance()
        }
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.preferredWidth(
                title: titleLabel.stringValue,
                secondaryText: secondaryLabel.isHidden ? nil : secondaryLabel.stringValue,
                indentationLevel: indentationLevel,
                isExpandable: isExpandable
            ),
            height: Layout.rowHeight
        )
    }

    override var isOpaque: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4

        disclosureButton.isBordered = false
        disclosureButton.bezelStyle = .regularSquare
        disclosureButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure)
        disclosureButton.contentTintColor = .secondaryLabelColor
        disclosureButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(disclosureButton)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(iconView)

        titleLabel.font = Self.titleFont
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(titleLabel)

        secondaryLabel.font = Self.titleFont
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.cell?.lineBreakMode = .byClipping
        secondaryLabel.cell?.usesSingleLineMode = true
        secondaryLabel.maximumNumberOfLines = 1
        secondaryLabel.alignment = .right
        secondaryLabel.isHidden = true
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(secondaryLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        secondaryText: String? = nil,
        indicatorImage: NSImage?,
        indentationLevel: Int,
        isExpandable: Bool,
        isExpanded: Bool,
        onOpen: @escaping () -> Void,
        onToggle: (() -> Void)?
    ) {
        self.indentationLevel = max(0, indentationLevel)
        self.isExpandable = isExpandable
        self.onOpen = onOpen
        self.onToggle = onToggle

        debugIdentifier = secondaryText.map { "\(title) | \($0)" } ?? title
        titleLabel.stringValue = title
        secondaryLabel.stringValue = secondaryText ?? ""
        secondaryLabel.isHidden = (secondaryText?.isEmpty ?? true)
        iconView.image = indicatorImage
        disclosureButton.isHidden = !isExpandable
        disclosureButton.title = isExpanded ? "▾" : "▸"

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func layout() {
        super.layout()

        let rowHeight = bounds.height
        let centerY = floor((rowHeight - Layout.iconSize) / 2)
        var x = Layout.horizontalPadding + CGFloat(indentationLevel) * Layout.indentationWidth

        if isExpandable {
            disclosureButton.frame = NSRect(
                x: x,
                y: floor((rowHeight - Layout.disclosureSize) / 2),
                width: Layout.disclosureSize,
                height: Layout.disclosureSize
            )
            x += Layout.disclosureSize + Layout.disclosureSpacing
        } else {
            disclosureButton.frame = .zero
        }

        iconView.frame = NSRect(
            x: x,
            y: centerY,
            width: Layout.iconSize,
            height: Layout.iconSize
        )
        x += Layout.iconSize + Layout.iconSpacing

        let secondaryWidth = secondaryLabel.isHidden
            ? CGFloat.zero
            : ceil(secondaryLabel.intrinsicContentSize.width)
        let secondaryHeight = secondaryLabel.isHidden
            ? CGFloat.zero
            : min(rowHeight, ceil(secondaryLabel.intrinsicContentSize.height))
        let trailingPadding = Layout.horizontalPadding
        let secondaryX = bounds.width - trailingPadding - secondaryWidth
        let titleWidth = max(
            0,
            secondaryX - x - (secondaryLabel.isHidden ? 0 : Layout.metadataSpacing)
        )
        let titleHeight = min(rowHeight, ceil(titleLabel.intrinsicContentSize.height))
        let titleY = floor((rowHeight - titleHeight) / 2)
        titleLabel.frame = NSRect(
            x: x,
            y: titleY,
            width: titleWidth,
            height: titleHeight
        )

        let secondaryY = floor((rowHeight - secondaryHeight) / 2)
        secondaryLabel.frame = NSRect(
            x: secondaryX,
            y: secondaryY,
            width: secondaryWidth,
            height: secondaryHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        if isHighlighted {
            Self.selectedFillColor.setFill()
            path.fill()
        } else if isHovered {
            Self.hoverFillColor.setFill()
            path.fill()
        } else {
            NSColor.clear.setFill()
            path.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        if !disclosureButton.isHidden, disclosureButton.frame.contains(point) {
            return disclosureButton
        }

        return self
    }

    override func mouseUp(with event: NSEvent) {
        DebugTraceLogger.log("overlay row mouseUp title=\(debugIdentifier) frame=\(debugScreenFrame())")
        onOpen?()
    }

    override func mouseDown(with event: NSEvent) {
        DebugTraceLogger.log("overlay row mouseDown title=\(debugIdentifier) frame=\(debugScreenFrame())")
        super.mouseDown(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isHovered else { return }
        isHovered = true
        needsDisplay = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isHovered else { return }
        isHovered = false
        needsDisplay = true
        updateAppearance()
    }

    @objc
    private func toggleDisclosure() {
        DebugTraceLogger.log("overlay row disclosure toggle title=\(debugIdentifier)")
        onToggle?()
    }

    private func updateAppearance() {
        let textColor: NSColor = (isHighlighted || isHovered)
            ? NSColor(calibratedWhite: 1, alpha: 0.98)
            : .labelColor
        titleLabel.textColor = textColor
        secondaryLabel.textColor = (isHighlighted || isHovered)
            ? NSColor(calibratedWhite: 1, alpha: 0.72)
            : .secondaryLabelColor
        disclosureButton.contentTintColor = (isHighlighted || isHovered)
            ? NSColor(calibratedWhite: 1, alpha: 0.92)
            : .secondaryLabelColor
    }

    private func debugScreenFrame() -> String {
        guard let window else {
            return "window=nil local=\(NSStringFromRect(frame))"
        }

        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)
        return NSStringFromRect(frameOnScreen)
    }
}
