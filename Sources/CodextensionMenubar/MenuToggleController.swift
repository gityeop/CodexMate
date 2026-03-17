import Foundation

@MainActor
final class MenuToggleController {
    private let openMenu: () -> Void
    private let closeMenu: () -> Void

    private(set) var isMenuPresented = false

    init(
        openMenu: @escaping () -> Void,
        closeMenu: @escaping () -> Void
    ) {
        self.openMenu = openMenu
        self.closeMenu = closeMenu
    }

    func toggleMenu() {
        if isMenuPresented {
            closeMenu()
        } else {
            openMenu()
        }
    }

    func menuWillOpen() {
        isMenuPresented = true
    }

    func menuDidClose() {
        isMenuPresented = false
    }
}
