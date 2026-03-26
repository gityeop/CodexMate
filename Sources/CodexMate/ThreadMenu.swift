import AppKit

enum ThreadMenuKeyboardShortcutAction: Equatable {
    case openHighlightedThread
    case openProjectThread(Int)
    case moveProjectSelection(Int)
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
            return .openHighlightedThread
        }

        if modifierFlags == .option {
            switch event.keyCode {
            case 125:
                return .moveProjectSelection(1)
            case 126:
                return .moveProjectSelection(-1)
            default:
                return nil
            }
        }

        guard modifierFlags == NSEvent.ModifierFlags.command,
              let characters = event.charactersIgnoringModifiers else {
            return nil
        }

        switch characters {
        case "1":
            return .openProjectThread(0)
        case "2":
            return .openProjectThread(1)
        case "3":
            return .openProjectThread(2)
        case "4":
            return .openProjectThread(3)
        case "5":
            return .openProjectThread(4)
        default:
            return nil
        }
    }
}
