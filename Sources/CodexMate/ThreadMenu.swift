import AppKit

enum ThreadMenuKeyboardShortcutAction: Equatable {
    case openHighlightedItem
    case openProjectThread(Int)
    case movePrimarySelection(Int)
    case moveBoundarySelection(Int)
    case togglePinnedThread
}

final class ThreadMenu: NSMenu {
    var onKeyboardShortcut: ((ThreadMenuKeyboardShortcutAction) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.shortcutAction(for: event) {
            if action == .togglePinnedThread {
                return super.performKeyEquivalent(with: event)
            }

            if onKeyboardShortcut?(action) == true {
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    static func shortcutAction(for event: NSEvent) -> ThreadMenuKeyboardShortcutAction? {
        guard event.type == .keyDown else {
            return nil
        }

        let modifierFlags = event.modifierFlags
            .intersection([.command, .option, .control, .shift])

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
                break
            }
        }

        if modifierFlags == .command {
            switch event.keyCode {
            case 125:
                return .moveBoundarySelection(1)
            case 126:
                return .moveBoundarySelection(-1)
            default:
                break
            }
        }

        guard modifierFlags == NSEvent.ModifierFlags.command,
              let characters = event.charactersIgnoringModifiers else {
            return nil
        }

        if characters.lowercased() == "p" {
            return .togglePinnedThread
        }

        guard let projectIndex = ProjectMenuShortcut.index(for: characters) else {
            return nil
        }

        return .openProjectThread(projectIndex)
    }
}
