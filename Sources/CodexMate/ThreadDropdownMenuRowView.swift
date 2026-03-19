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
        static let minimumWidth: CGFloat = 220
    }

    private static let titleFont = NSFont.systemFont(ofSize: 13)

    static func preferredWidth(
        title: String,
        indentationLevel: Int,
        isExpandable: Bool
    ) -> CGFloat {
        let titleWidth = ceil(
            NSString(string: title).size(withAttributes: [.font: titleFont]).width
        )
        let disclosureWidth = isExpandable ? Layout.disclosureSize + Layout.disclosureSpacing : 0
        let indentationWidth = CGFloat(max(0, indentationLevel)) * Layout.indentationWidth
        let iconWidth = Layout.iconSize + Layout.iconSpacing
        let contentWidth = Layout.horizontalPadding * 2
            + indentationWidth
            + disclosureWidth
            + iconWidth
            + titleWidth
        let width = ceil(contentWidth)

        return max(Layout.minimumWidth, width)
    }

    private let disclosureButton = NSButton(title: "▸", target: nil, action: nil)
    private let iconView = NSImageView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private var indentationLevel: Int = 0
    private var isExpandable = false
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
                indentationLevel: indentationLevel,
                isExpandable: isExpandable
            ),
            height: Layout.rowHeight
        )
    }

    override var isOpaque: Bool {
        false
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
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

        titleLabel.stringValue = title
        iconView.image = indicatorImage
        disclosureButton.isHidden = !isExpandable
        disclosureButton.title = isExpanded ? "▾" : "▸"

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateAppearance()
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

        let titleWidth = max(0, bounds.width - x - Layout.horizontalPadding)
        let titleHeight = min(rowHeight, ceil(titleLabel.intrinsicContentSize.height))
        let titleY = floor((rowHeight - titleHeight) / 2)
        titleLabel.frame = NSRect(
            x: x,
            y: titleY,
            width: titleWidth,
            height: titleHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if isHighlighted {
            NSColor.selectedMenuItemColor.setFill()
            path.fill()
        } else {
            NSColor.clear.setFill()
            path.fill()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if !disclosureButton.isHidden, disclosureButton.frame.contains(point) {
            return disclosureButton
        }

        return self
    }

    override func mouseUp(with event: NSEvent) {
        onOpen?()
    }

    @objc
    private func toggleDisclosure() {
        onToggle?()
    }

    private func updateAppearance() {
        let textColor: NSColor = isHighlighted ? .selectedMenuItemTextColor : .labelColor
        titleLabel.textColor = textColor
        disclosureButton.contentTintColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
    }
}
