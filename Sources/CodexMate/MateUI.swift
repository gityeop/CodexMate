import AppKit
import SwiftUI

/// Shared desktop metrics and adaptive surfaces. Keep accent color for actions and focus.
enum MateUI {
    static let controlHeight: CGFloat = 32
    static let compactHeight: CGFloat = 24
    static let compactCornerRadius: CGFloat = 6
    static let compactFontSize: CGFloat = 12
    static let cornerRadius: CGFloat = 7
    static let iconSize: CGFloat = 12
    static let spacing: CGFloat = 8
    static let inset: CGFloat = 12
    static let sectionSpacing: CGFloat = 20
    static let font = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let transitionDuration = 0.18

    static let canvas = Color(nsColor: neutral(light: 0.975, dark: 0.115))
    static let panel = Color(nsColor: neutral(light: 0.955, dark: 0.135))
    static let control = Color(nsColor: controlColor)
    static let controlColor = neutral(light: 0.99, dark: 0.18)
    static let softControlColor = neutral(light: 0.965, dark: 0.16)
    static let border = Color(nsColor: borderColor)
    static let borderColor = neutral(light: 0, dark: 1, lightAlpha: 0.10, darkAlpha: 0.09)
    static let hover = Color.primary.opacity(0.045)
    static let pressed = Color.primary.opacity(0.08)
    static let focus = Color.accentColor
    static let disabledOpacity = 0.45

    private static func neutral(light: CGFloat, dark: CGFloat, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
}

struct MateButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive, card }
    var kind: Kind = .secondary
    var iconOnly = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: configuration.role == .destructive ? .destructive : kind,
             iconOnly: iconOnly, compact: compact)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        let iconOnly: Bool
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var filled: Bool { kind == .primary || kind == .destructive }
        private var height: CGFloat { compact ? MateUI.compactHeight : MateUI.controlHeight }
        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MateUI.cornerRadius) }
        private var fill: Color {
            if kind == .primary { return .accentColor }
            if kind == .destructive { return .red }
            return kind == .ghost ? .clear : MateUI.control
        }

        var body: some View {
            configuration.label
                .font(compact ? MateUI.caption : MateUI.font.weight(.medium))
                .foregroundStyle(filled ? Color.white : Color.primary)
                .padding(.horizontal, iconOnly ? 0 : MateUI.inset)
                .padding(.vertical, kind == .card ? MateUI.inset : 0)
                .frame(width: iconOnly ? height : nil, height: kind == .card ? nil : height)
                .background(fill, in: shape)
                .background {
                    if kind != .ghost { shape.shadow(color: .black.opacity(0.04), radius: 1, y: 1) }
                }
                .overlay {
                    shape.fill(isEnabled && configuration.isPressed ? MateUI.pressed : isEnabled && hovering ? MateUI.hover : .clear)
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(isFocused ? MateUI.focus : border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    if kind != .ghost {
                        Color.white.opacity(0.06).frame(height: 0.5)
                            .padding(.horizontal, MateUI.cornerRadius).allowsHitTesting(false)
                    }
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : MateUI.disabledOpacity)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: MateUI.transitionDuration), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: MateUI.transitionDuration), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var border: Color {
            if kind == .ghost && !hovering { return .clear }
            if filled { return Color.black.opacity(0.10) }
            return hovering && isEnabled ? Color.primary.opacity(0.18) : MateUI.border
        }
    }
}

/// Native text editing keeps IME composition, selection and the responder-chain edit commands.
struct MateSearchField: View {
    let title: String
    let clearLabel: String
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: MateUI.spacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: MateUI.iconSize)).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(title).foregroundColor(.secondary))
                .textFieldStyle(.plain)
                .font(MateUI.font)
                .focused($focused)
                .accessibilityLabel(title)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(MateButtonStyle(kind: .ghost, iconOnly: true, compact: true))
                .help(clearLabel).accessibilityLabel(clearLabel)
            }
        }
        .padding(.leading, MateUI.inset)
        .padding(.trailing, 4)
        .frame(height: MateUI.controlHeight)
        .background(MateUI.control, in: RoundedRectangle(cornerRadius: MateUI.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: MateUI.cornerRadius)
                .strokeBorder(focused ? MateUI.focus : hovering ? Color.primary.opacity(0.20) : MateUI.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .opacity(isEnabled ? 1 : MateUI.disabledOpacity)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: MateUI.transitionDuration), value: focused)
        .animation(reduceMotion ? nil : .easeOut(duration: MateUI.transitionDuration), value: hovering)
    }
}
