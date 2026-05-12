import Foundation

@MainActor
final class MenuToggleController {
    private let openMenu: () -> Void
    private let closeMenu: () -> Void
    private let canOpenMenu: () -> Bool

    private(set) var isMenuPresented = false

    init(
        canOpenMenu: @escaping () -> Bool = { true },
        openMenu: @escaping () -> Void,
        closeMenu: @escaping () -> Void
    ) {
        self.canOpenMenu = canOpenMenu
        self.openMenu = openMenu
        self.closeMenu = closeMenu
    }

    func toggleMenu() {
        if isMenuPresented {
            isMenuPresented = false
            closeMenu()
        } else {
            guard canOpenMenu() else {
                return
            }

            isMenuPresented = true
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
