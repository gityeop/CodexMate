import AppKit
import SwiftUI

/// AppKit keeps the whole styled dropdown clickable; SwiftUI's macOS Menu flattens its label.
struct MateMenuPicker<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let options: [Selection]
    let label: (Selection) -> String

    var body: some View {
        HStack(spacing: MateUI.inset) {
            Text(title)
            Spacer()
            MatePopUp(selection: $selection, options: options, labels: options.map(label), title: title)
                .fixedSize()
        }.font(MateUI.font)
    }
}

private struct MatePopUp<Selection: Hashable>: NSViewRepresentable {
    @Binding var selection: Selection
    let options: [Selection]
    let labels: [String]
    let title: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MatePopUpButton {
        let button = MatePopUpButton(frame: .zero, pullsDown: false)
        button.cell = MatePopUpCell(textCell: "", pullsDown: false)
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: MateUI.compactFontSize)
        button.focusRingType = .none
        button.alignment = .left
        (button.cell as! NSPopUpButtonCell).arrowPosition = .noArrow
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: MatePopUpButton, context: Context) {
        context.coordinator.parent = self
        if button.itemTitles != labels {
            button.removeAllItems()
            button.addItems(withTitles: labels)
        }
        button.selectItem(at: options.firstIndex(of: selection)!)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        button.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MatePopUp
        init(parent: MatePopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            parent.selection = parent.options[sender.indexOfSelectedItem]
        }
    }
}

private final class MatePopUpButton: NSPopUpButton {
    private var hoverTracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: MateUI.compactFontSize)]).width + 32,
               height: MateUI.compactHeight)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { (cell as! MatePopUpCell).hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { (cell as! MatePopUpCell).hovering = false; needsDisplay = true }
}

private final class MatePopUpCell: NSPopUpButtonCell {
    var hovering = false

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: MateUI.compactCornerRadius, yRadius: MateUI.compactCornerRadius)
        MateUI.softControlColor.setFill()
        shape.fill()
        if isEnabled && (hovering || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.06 : 0.025).setFill()
            shape.fill()
        }
        let focused = controlView.window?.firstResponder === controlView && controlView.window?.isKeyWindow == true
        let border = focused ? NSColor.controlAccentColor.withAlphaComponent(0.75)
            : hovering && isEnabled ? NSColor.labelColor.withAlphaComponent(0.16) : MateUI.borderColor
        border.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func drawInterior(withFrame frame: NSRect, in controlView: NSView) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: MateUI.compactFontSize),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        ]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        let titleFrame = NSRect(x: frame.minX + 8, y: frame.midY - textHeight / 2,
                               width: frame.width - 28, height: textHeight)
        (title as NSString).draw(in: titleFrame, withAttributes: attributes)
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: frame.maxX - 14, y: frame.midY - 1))
        arrow.line(to: NSPoint(x: frame.maxX - 11, y: frame.midY + 2))
        arrow.line(to: NSPoint(x: frame.maxX - 8, y: frame.midY - 1))
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        arrow.lineWidth = 1
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.stroke()
    }
}
