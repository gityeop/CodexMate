import AppKit

@MainActor
final class ThreadHoverTooltipController {
    private let tooltipView = ThreadHoverTooltipView()
    private lazy var panel: ThreadHoverTooltipPanel = {
        let panel = ThreadHoverTooltipPanel(
            contentRect: NSRect(x: 0, y: 0, width: ThreadHoverTooltipView.maxWidth, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = tooltipView
        return panel
    }()

    var isVisible: Bool {
        panel.isVisible
    }

    func show(
        content: MenubarStatusPresentation.ThreadTooltipContent,
        near screenPoint: NSPoint,
        avoidingMenuWidth menuWidth: CGFloat,
        menuFrame: NSRect?
    ) {
        guard !content.lines.isEmpty else {
            hide()
            return
        }

        tooltipView.apply(content: content)
        let size = tooltipView.fittingPanelSize
        panel.setContentSize(size)
        panel.setFrameOrigin(
            panelOrigin(
                near: screenPoint,
                size: size,
                avoidingMenuWidth: menuWidth,
                menuFrame: menuFrame
            )
        )
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func panelOrigin(
        near screenPoint: NSPoint,
        size: NSSize,
        avoidingMenuWidth menuWidth: CGFloat,
        menuFrame: NSRect?
    ) -> NSPoint {
        // Slight overlap cancels the visible seam caused by the floating panel shadow.
        let horizontalGap: CGFloat = -2
        let margin: CGFloat = 12
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900))

        let originX: CGFloat
        if let menuFrame, !menuFrame.isEmpty {
            let preferredLeftOriginX = menuFrame.minX - size.width - horizontalGap
            let fallbackRightOriginX = menuFrame.maxX + horizontalGap

            if preferredLeftOriginX >= visibleFrame.minX + margin {
                originX = preferredLeftOriginX
            } else if fallbackRightOriginX + size.width <= visibleFrame.maxX - margin {
                originX = fallbackRightOriginX
            } else {
                originX = max(
                    visibleFrame.minX + margin,
                    min(preferredLeftOriginX, visibleFrame.maxX - size.width - margin)
                )
            }
        } else {
            let menuClearance = max(menuWidth, 240) + horizontalGap
            let rightOriginX = screenPoint.x + menuClearance
            let leftOriginX = screenPoint.x - menuClearance - size.width
            let canFitLeft = leftOriginX >= visibleFrame.minX + margin
            let canFitRight = rightOriginX + size.width <= visibleFrame.maxX - margin

            if canFitLeft || !canFitRight {
                originX = max(visibleFrame.minX + margin, min(leftOriginX, visibleFrame.maxX - size.width - margin))
            } else {
                originX = max(visibleFrame.minX + margin, min(rightOriginX, visibleFrame.maxX - size.width - margin))
            }
        }

        var originY = screenPoint.y - (size.height / 2)
        originY = max(visibleFrame.minY + margin, min(originY, visibleFrame.maxY - size.height - margin))

        return NSPoint(x: originX, y: originY)
    }
}

private final class ThreadHoverTooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ThreadHoverTooltipView: NSView {
    static let maxWidth: CGFloat = 300

    private let backgroundView = NSVisualEffectView()
    private let containerStack = NSStackView()
    private let headerStack = NSStackView()
    private let headerLabel = ThreadHoverTooltipView.makeHeaderLabel()
    private let worktreeLabel = ThreadHoverTooltipView.makeWorktreeLabel()
    private let titleLabel = ThreadHoverTooltipView.makeTitleLabel()
    private let detailStack = NSStackView()
    private let previewLabel = ThreadHoverTooltipView.makePreviewLabel()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .popover
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 14
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 8

        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.addArrangedSubview(headerLabel)
        headerStack.addArrangedSubview(worktreeLabel)

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6

        addSubview(backgroundView)
        backgroundView.addSubview(containerStack)

        containerStack.addArrangedSubview(headerStack)
        containerStack.addArrangedSubview(titleLabel)
        containerStack.addArrangedSubview(detailStack)
        containerStack.addArrangedSubview(previewLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.maxWidth),

            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            containerStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            containerStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 12),
            containerStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var fittingPanelSize: NSSize {
        layoutSubtreeIfNeeded()
        let contentHeight = containerStack.fittingSize.height + 24
        return NSSize(width: Self.maxWidth, height: ceil(contentHeight))
    }

    func apply(content: MenubarStatusPresentation.ThreadTooltipContent) {
        headerStack.isHidden = content.worktreeDisplayName == nil
        worktreeLabel.stringValue = content.worktreeDisplayName ?? ""

        titleLabel.isHidden = content.title == nil
        titleLabel.stringValue = content.title ?? ""

        for subview in detailStack.arrangedSubviews {
            detailStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for detail in content.details {
            detailStack.addArrangedSubview(ThreadHoverTooltipDetailView(detail: detail))
        }
        detailStack.isHidden = content.details.isEmpty

        previewLabel.isHidden = content.preview == nil
        previewLabel.stringValue = content.preview ?? ""
    }

    private static func makeHeaderLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "WORKTREE")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private static func makeWorktreeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func makeTitleLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        return label
    }

    private static func makePreviewLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        return label
    }
}

private final class ThreadHoverTooltipDetailView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    init(detail: MenubarStatusPresentation.ThreadTooltipContent.Detail) {
        super.init(frame: .zero)

        let style = Self.style(for: detail.kind)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.backgroundColor = style.background.cgColor
        layer?.borderColor = style.border.cgColor

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = style.text
        label.stringValue = detail.displayText
        label.maximumNumberOfLines = 3

        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func style(
        for kind: MenubarStatusPresentation.ThreadTooltipContent.Detail.Kind
    ) -> (background: NSColor, border: NSColor, text: NSColor) {
        switch kind {
        case .approval:
            return (
                background: NSColor.systemOrange.withAlphaComponent(0.12),
                border: NSColor.systemOrange.withAlphaComponent(0.24),
                text: NSColor.systemOrange
            )
        case .error:
            return (
                background: NSColor.systemRed.withAlphaComponent(0.12),
                border: NSColor.systemRed.withAlphaComponent(0.24),
                text: NSColor.systemRed
            )
        }
    }
}
