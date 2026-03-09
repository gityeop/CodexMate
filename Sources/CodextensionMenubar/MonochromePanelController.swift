import AppKit

private enum MonochromePalette {
    static let panelBackground = NSColor(calibratedWhite: 0.94, alpha: 1)
    static let surfaceBackground = NSColor(calibratedWhite: 0.99, alpha: 1)
    static let primaryText = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.34, alpha: 1)
    static let border = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let hoverFill = NSColor(calibratedWhite: 0.08, alpha: 0.06)
}

@MainActor
final class StatusItemBadgeField: NSTextField {
    private let horizontalPadding: CGFloat = 6
    private let verticalPadding: CGFloat = 2

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: max(18, base.width + (horizontalPadding * 2)),
            height: max(18, base.height + (verticalPadding * 2))
        )
    }

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        textColor = .white
        lineBreakMode = .byClipping
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 9
        layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class CapsuleLabel: NSTextField {
    enum Style {
        case outline
        case filled
    }

    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 4

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(
            width: base.width + (horizontalPadding * 2),
            height: max(24, base.height + (verticalPadding * 2))
        )
    }

    init(text: String, style: Style) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        font = .systemFont(ofSize: 11, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1

        switch style {
        case .outline:
            textColor = MonochromePalette.primaryText
            layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
            layer?.borderColor = MonochromePalette.border.cgColor
        case .filled:
            textColor = .white
            layer?.backgroundColor = MonochromePalette.border.cgColor
            layer?.borderColor = MonochromePalette.border.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class FloatingStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ThreadRowControl: NSControl {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private var trackingAreaRef: NSTrackingArea?
    private var threadID: String = ""

    var onPress: ((String, Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MonochromePalette.border.withAlphaComponent(0.12).cgColor

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iconView.contentTintColor = MonochromePalette.primaryText

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.textColor = MonochromePalette.primaryText
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        previewField.translatesAutoresizingMaskIntoConstraints = false
        previewField.font = .systemFont(ofSize: 12)
        previewField.lineBreakMode = .byTruncatingTail
        previewField.maximumNumberOfLines = 1
        previewField.textColor = MonochromePalette.secondaryText
        previewField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeField.translatesAutoresizingMaskIntoConstraints = false
        timeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeField.alignment = .right
        timeField.textColor = MonochromePalette.secondaryText
        timeField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [titleField, timeField])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 8
        headerRow.distribution = .fill

        let textStack = NSStackView(views: [headerRow, previewField])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .width
        textStack.spacing = 3

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        thread: AppStateStore.ThreadRow,
        relativeDateFormatter: RelativeDateTimeFormatter
    ) {
        threadID = thread.id
        titleField.stringValue = thread.displayTitle
        previewField.stringValue = thread.preview
        timeField.stringValue = relativeDateFormatter.localizedString(for: thread.updatedAt, relativeTo: Date())
        iconView.image = Self.symbolImage(for: thread.status)
        toolTip = "\(thread.preview)\n\(thread.cwd)"
        setAccessibilityLabel("\(thread.displayTitle), \(thread.status.displayName)")
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(threadID, event.modifierFlags.contains(.option))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = MonochromePalette.hoverFill.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
    }

    private static func symbolImage(for status: AppStateStore.ThreadStatus) -> NSImage? {
        let symbolName: String

        switch status {
        case .waitingForInput:
            symbolName = "ellipsis.bubble"
        case .needsApproval:
            symbolName = "hand.raised"
        case .failed:
            symbolName = "exclamationmark.triangle"
        case .running:
            symbolName = "hourglass"
        case .idle, .notLoaded:
            symbolName = "checkmark.circle"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}

@MainActor
final class MonochromePanelController: NSObject, NSWindowDelegate {
    struct Model {
        let title: String
        let subtitle: String
        let bannerText: String?
        let projects: [AppStateStore.ProjectPanel]
    }

    var onRefresh: (() -> Void)?
    var onThreadSelected: ((String, Bool) -> Void)?

    private let panel: FloatingStatusPanel
    private let contentRootView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let bannerField = NSTextField(labelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let pinButton = NSButton(image: NSImage(), target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let cardStackView = NSStackView()
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private var scrollTopToHeaderConstraint: NSLayoutConstraint?
    private var scrollTopToBannerConstraint: NSLayoutConstraint?

    private weak var anchorButton: NSStatusBarButton?
    private var currentModel: Model?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private(set) var isPinned = false
    private var ignoreDismissUntil: Date?

    override init() {
        panel = FloatingStatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureContent()
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func toggle(relativeTo button: NSStatusBarButton, model: Model) {
        if panel.isVisible {
            close()
            return
        }

        show(relativeTo: button, model: model)
    }

    func show(relativeTo button: NSStatusBarButton, model: Model) {
        anchorButton = button
        update(model: model)
        reposition(relativeTo: button)
        ignoreDismissUntil = Date().addingTimeInterval(0.25)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            self?.refreshDismissMonitoring()
        }
    }

    func update(model: Model) {
        currentModel = model
        titleField.stringValue = model.title
        subtitleField.stringValue = model.subtitle

        if let bannerText = model.bannerText, !bannerText.isEmpty {
            bannerField.isHidden = false
            bannerField.stringValue = bannerText
            scrollTopToHeaderConstraint?.isActive = false
            scrollTopToBannerConstraint?.isActive = true
        } else {
            bannerField.isHidden = true
            bannerField.stringValue = ""
            scrollTopToBannerConstraint?.isActive = false
            scrollTopToHeaderConstraint?.isActive = true
        }

        rebuildProjectCards(with: model.projects)

        if panel.isVisible, !isPinned, let anchorButton {
            reposition(relativeTo: anchorButton)
        }
    }

    func close() {
        stopDismissMonitoring()
        panel.orderOut(nil)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        pinButton.state = pinned ? .on : .off
        updatePinButtonImage()
        refreshDismissMonitoring()
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = MonochromePalette.panelBackground
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.delegate = self
    }

    private func configureContent() {
        contentRootView.wantsLayer = true
        contentRootView.appearance = NSAppearance(named: .aqua)
        contentRootView.layer?.backgroundColor = MonochromePalette.panelBackground.cgColor
        panel.contentView = contentRootView

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 18, weight: .bold)
        titleField.textColor = MonochromePalette.primaryText

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleField.textColor = MonochromePalette.secondaryText
        subtitleField.maximumNumberOfLines = 2
        subtitleField.lineBreakMode = .byWordWrapping

        bannerField.translatesAutoresizingMaskIntoConstraints = false
        bannerField.font = .systemFont(ofSize: 12, weight: .medium)
        bannerField.textColor = MonochromePalette.primaryText
        bannerField.maximumNumberOfLines = 2
        bannerField.wantsLayer = true
        bannerField.layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
        bannerField.layer?.borderColor = MonochromePalette.border.cgColor
        bannerField.layer?.borderWidth = 1
        bannerField.layer?.cornerRadius = 10
        bannerField.isHidden = true

        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.target = self
        refreshButton.action = #selector(handleRefresh)
        refreshButton.isBordered = false
        refreshButton.controlSize = .small
        refreshButton.wantsLayer = true
        refreshButton.layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
        refreshButton.layer?.borderColor = MonochromePalette.border.cgColor
        refreshButton.layer?.borderWidth = 1
        refreshButton.layer?.cornerRadius = 10
        refreshButton.contentTintColor = MonochromePalette.primaryText
        refreshButton.attributedTitle = NSAttributedString(
            string: "Refresh",
            attributes: [
                .foregroundColor: MonochromePalette.primaryText,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        refreshButton.widthAnchor.constraint(equalToConstant: 88).isActive = true
        refreshButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.target = self
        pinButton.action = #selector(togglePin)
        pinButton.setButtonType(.toggle)
        pinButton.isBordered = false
        pinButton.controlSize = .small
        pinButton.contentTintColor = MonochromePalette.primaryText
        pinButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        pinButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updatePinButtonImage()

        let titleStack = NSStackView(views: [titleField, subtitleField])
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4
        titleStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let buttonStack = NSStackView(views: [refreshButton, pinButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [titleStack, makeFlexibleSpacer(), buttonStack])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 12
        headerRow.distribution = .fill

        cardStackView.translatesAutoresizingMaskIntoConstraints = false
        cardStackView.orientation = .vertical
        cardStackView.alignment = .width
        cardStackView.spacing = 16

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(cardStackView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        contentRootView.addSubview(headerRow)
        contentRootView.addSubview(bannerField)
        contentRootView.addSubview(scrollView)

        scrollTopToHeaderConstraint = scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14)
        scrollTopToBannerConstraint = scrollView.topAnchor.constraint(equalTo: bannerField.bottomAnchor, constant: 14)
        scrollTopToHeaderConstraint?.isActive = true

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: contentRootView.topAnchor, constant: 18),
            headerRow.leadingAnchor.constraint(equalTo: contentRootView.leadingAnchor, constant: 18),
            headerRow.trailingAnchor.constraint(equalTo: contentRootView.trailingAnchor, constant: -18),

            bannerField.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 14),
            bannerField.leadingAnchor.constraint(equalTo: contentRootView.leadingAnchor, constant: 18),
            bannerField.trailingAnchor.constraint(equalTo: contentRootView.trailingAnchor, constant: -18),

            scrollView.leadingAnchor.constraint(equalTo: contentRootView.leadingAnchor, constant: 0),
            scrollView.trailingAnchor.constraint(equalTo: contentRootView.trailingAnchor, constant: 0),
            scrollView.bottomAnchor.constraint(equalTo: contentRootView.bottomAnchor, constant: -14),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            cardStackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            cardStackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 18),
            cardStackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -18),
            cardStackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    private func rebuildProjectCards(with projects: [AppStateStore.ProjectPanel]) {
        for view in cardStackView.arrangedSubviews {
            cardStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !projects.isEmpty else {
            addCardView(makeEmptyStateView())
            return
        }

        var index = 0
        while index < projects.count {
            let rowStack = NSStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.orientation = .horizontal
            rowStack.alignment = .top
            rowStack.distribution = .fillEqually
            rowStack.spacing = 16

            rowStack.addArrangedSubview(makeProjectCard(for: projects[index]))

            if index + 1 < projects.count {
                rowStack.addArrangedSubview(makeProjectCard(for: projects[index + 1]))
            } else {
                rowStack.addArrangedSubview(makeProjectGridSpacer())
            }

            addCardView(rowStack)
            index += 2
        }
    }

    private func addCardView(_ view: NSView) {
        cardStackView.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: cardStackView.widthAnchor).isActive = true
    }

    private func makeEmptyStateView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
        container.layer?.borderColor = MonochromePalette.border.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 14

        let title = NSTextField(labelWithString: "No recent threads")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = MonochromePalette.primaryText

        let subtitle = NSTextField(labelWithString: "Open a Codex thread and it will appear here.")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = MonochromePalette.secondaryText

        container.addSubview(title)
        container.addSubview(subtitle)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            subtitle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
        ])

        return container
    }

    private func makeProjectCard(for project: AppStateStore.ProjectPanel) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = MonochromePalette.surfaceBackground.cgColor
        container.layer?.borderColor = MonochromePalette.border.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 14

        let projectName = NSTextField(labelWithString: project.displayName)
        projectName.translatesAutoresizingMaskIntoConstraints = false
        projectName.font = .systemFont(ofSize: 15, weight: .bold)
        projectName.lineBreakMode = .byTruncatingTail
        projectName.maximumNumberOfLines = 1
        projectName.textColor = MonochromePalette.primaryText
        projectName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectName.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusPill = CapsuleLabel(text: statusLabel(for: project.dominantStatus), style: .filled)
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.setContentCompressionResistancePriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [projectName, makeFlexibleSpacer(), statusPill])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.distribution = .fill

        let summaryField = makeSecondaryLabel(summaryText(for: project))
        summaryField.lineBreakMode = .byTruncatingTail
        summaryField.maximumNumberOfLines = 1
        summaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let updatedField = makeSecondaryLabel("Updated \(relativeDateFormatter.localizedString(for: project.latestUpdatedAt, relativeTo: Date()))")
        updatedField.maximumNumberOfLines = 1
        updatedField.alignment = .right
        updatedField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let summaryRow = NSStackView(views: [summaryField, makeFlexibleSpacer(), updatedField])
        summaryRow.translatesAutoresizingMaskIntoConstraints = false
        summaryRow.orientation = .horizontal
        summaryRow.alignment = .firstBaseline
        summaryRow.spacing = 10
        summaryRow.distribution = .fill

        let threadStack = NSStackView()
        threadStack.translatesAutoresizingMaskIntoConstraints = false
        threadStack.orientation = .vertical
        threadStack.alignment = .width
        threadStack.spacing = 6

        for thread in project.threads {
            let row = ThreadRowControl()
            row.configure(thread: thread, relativeDateFormatter: relativeDateFormatter)
            row.onPress = { [weak self] threadID, copyOnly in
                self?.onThreadSelected?(threadID, copyOnly)

                if self?.isPinned == false {
                    self?.close()
                }
            }
            threadStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: threadStack.widthAnchor).isActive = true
        }

        if project.hiddenThreadCount > 0 {
            let moreField = NSTextField(labelWithString: "+\(project.hiddenThreadCount) more")
            moreField.translatesAutoresizingMaskIntoConstraints = false
            moreField.font = .systemFont(ofSize: 12, weight: .medium)
            moreField.textColor = MonochromePalette.secondaryText
            moreField.lineBreakMode = .byTruncatingTail
            threadStack.addArrangedSubview(moreField)
        }

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator

        let stack = NSStackView(views: [headerRow, summaryRow, divider, threadStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12

        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        return container
    }

    private func makeProjectGridSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        return spacer
    }

    private func statusLabel(for status: AppStateStore.ThreadStatus) -> String {
        switch status {
        case .waitingForInput:
            return "Reply Needed"
        case .needsApproval:
            return "Approval Needed"
        case .failed:
            return "Issue"
        case .running:
            return "Running"
        case .idle, .notLoaded:
            return "Idle"
        }
    }

    private func summaryText(for project: AppStateStore.ProjectPanel) -> String {
        var segments = [
            "Reply \(project.waitingForInputCount)",
            "Approval \(project.approvalCount)",
            "Running \(project.runningCount)"
        ]

        if project.failedCount > 0 {
            segments.append("Issues \(project.failedCount)")
        }

        return segments.joined(separator: " · ")
    }

    private func makeSecondaryLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = MonochromePalette.secondaryText
        return field
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func reposition(relativeTo button: NSStatusBarButton) {
        guard let screen = button.window?.screen ?? NSScreen.screens.first else {
            return fallbackReposition()
        }

        guard let buttonRect = screenRect(for: button) else {
            return fallbackReposition(on: screen)
        }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let preferredX = buttonRect.maxX - panelSize.width
        let clampedX = min(max(preferredX, visibleFrame.minX + 12), visibleFrame.maxX - panelSize.width - 12)
        let originY = max(visibleFrame.minY + 12, buttonRect.minY - panelSize.height - 8)
        panel.setFrameOrigin(NSPoint(x: clampedX, y: originY))
    }

    private func fallbackReposition(on screen: NSScreen? = NSScreen.main ?? NSScreen.screens.first) {
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - panelSize.width - 20,
            y: visibleFrame.maxY - panelSize.height - 40
        )
        panel.setFrameOrigin(origin)
    }

    private func screenRect(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let rectInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }

    private func refreshDismissMonitoring() {
        if isPinned || !panel.isVisible {
            stopDismissMonitoring()
        } else {
            startDismissMonitoring()
        }
    }

    private func startDismissMonitoring() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handleLocalEvent(event) ?? event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleGlobalMouseEvent(event)
        }
    }

    private func stopDismissMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, !isPinned else { return event }
        guard shouldHandleDismissEvent else { return event }

        if event.type == .keyDown, event.keyCode == 53 {
            close()
            return nil
        }

        let screenPoint = screenPoint(for: event)
        if shouldDismiss(for: screenPoint) {
            close()
        }

        return event
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard panel.isVisible, !isPinned else { return }
        guard shouldHandleDismissEvent else { return }

        if shouldDismiss(for: event.locationInWindow) {
            close()
        }
    }

    private var shouldHandleDismissEvent: Bool {
        guard let ignoreDismissUntil else { return true }
        return Date() >= ignoreDismissUntil
    }

    private func shouldDismiss(for screenPoint: NSPoint) -> Bool {
        if panel.frame.contains(screenPoint) {
            return false
        }

        if let anchorButton, let anchorRect = screenRect(for: anchorButton), anchorRect.contains(screenPoint) {
            return false
        }

        return true
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }

        return event.locationInWindow
    }

    private func updatePinButtonImage() {
        let symbolName = isPinned ? "pin.fill" : "pin"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        pinButton.image = image
        pinButton.contentTintColor = MonochromePalette.primaryText
        pinButton.state = isPinned ? .on : .off
    }

    @objc
    private func handleRefresh() {
        onRefresh?()
    }

    @objc
    private func togglePin(_ sender: NSButton) {
        setPinned(sender.state == .on)
    }

    func windowWillClose(_ notification: Notification) {
        stopDismissMonitoring()
    }
}
