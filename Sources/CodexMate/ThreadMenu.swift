import AppKit

enum ThreadMenuKeyboardShortcutAction: Equatable {
    case openHighlightedItem
    case openProjectThread(Int)
    case movePrimarySelection(Int)
}

final class ThreadMenu: NSMenu {
    var onKeyboardShortcut: ((ThreadMenuKeyboardShortcutAction) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.shortcutAction(for: event),
           onKeyboardShortcut?(action) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    static func shortcutAction(for event: NSEvent) -> ThreadMenuKeyboardShortcutAction? {
        guard event.type == .keyDown else {
            return nil
        }

        let modifierFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])

        if modifierFlags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
            return .openHighlightedItem
        }

        if modifierFlags == .option {
            switch event.keyCode {
            case 125:
                return .movePrimarySelection(1)
            case 126:
                return .movePrimarySelection(-1)
            default:
                return nil
            }
        }

        guard modifierFlags == NSEvent.ModifierFlags.command,
              let characters = event.charactersIgnoringModifiers else {
            return nil
        }

        guard let projectIndex = ProjectMenuShortcut.index(for: characters) else {
            return nil
        }

        return .openProjectThread(projectIndex)
    }
}
