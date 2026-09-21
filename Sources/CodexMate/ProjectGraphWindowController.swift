import AppKit
import SwiftUI

/// Keep the existing AppKit lifecycle; SwiftUI owns the contents of this singleton window.
@MainActor
final class ProjectGraphWindowController: NSWindowController, NSWindowDelegate {
    private let store: ProjectGraphStore
    private var refreshTimer: Timer?

    init(store: ProjectGraphStore, openThread: @escaping (String) -> Void, openSettings: @escaping () -> Void) {
        self.store = store
        let view = ProjectGraphView(store: store, openThread: openThread, openSettings: openSettings)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "CodexMate — Git Graph"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1280, height: 780))
        window.minSize = NSSize(width: 980, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CodexMateProjectGraph")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if window?.isMiniaturized == true { window?.deminiaturize(sender) }
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshing()
    }

    func windowDidBecomeKey(_ notification: Notification) { store.refresh() }
    func windowDidDeminiaturize(_ notification: Notification) { startRefreshing() }
    func windowDidMiniaturize(_ notification: Notification) { stopRefreshing() }
    func windowWillClose(_ notification: Notification) { stopRefreshing() }

    private func startRefreshing() {
        store.setVisible(true)
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }
        refreshTimer?.tolerance = 2
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        store.setVisible(false)
    }
}
