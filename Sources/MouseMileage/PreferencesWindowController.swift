import AppKit
import Combine
import SwiftUI

final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private let viewModel = PreferencesViewModel()
    private let batteryViewModel = BatteryViewModel()
    private let tabState = PreferencesTabState()
    private var tabObserver: AnyCancellable?

    /// The width the tabs are laid out for, and the smallest the window can be dragged to.
    static let width: CGFloat = 500
    static let minimumSize = NSSize(width: width, height: 280)

    /// The content size the user last dragged the window to (per Mac, not synced), or nil
    /// while they haven't: then each tab opens at its own height.
    static var chosenSize: NSSize? {
        get { AppDefaults.store.string(forKey: "settings.contentSize").map(NSSizeFromString) }
        set { AppDefaults.store.set(newValue.map(NSStringFromSize), forKey: "settings.contentSize") }
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        viewModel.refreshText()
        viewModel.refreshSettings()
        batteryViewModel.refresh()
        fit(tabState.tab, animate: false)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // After an update whose notes weren't seen yet. Always on the main thread.
        if let window { MainActor.assumeIsolated { WhatsNew.shared.present(on: window) } }
        // The refreshes above can change what the tab shows (Macs, mice) a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.fit(self.tabState.tab, animate: true)
        }
    }

    /// This version's release notes, when asked for from Settings.
    func showWhatsNew() {
        if let window { MainActor.assumeIsolated { WhatsNew.shared.present(on: window, asked: true) } }
    }

    #if DEBUG
    var debugWindow: NSWindow? { window }
    func debugSelect(_ tab: PreferencesTab) { tabState.tab = tab }
    #endif

    private func makeWindow() -> NSWindow {
        // Sized here, to each tab's natural height capped to the screen, with the tab
        // scrolling inside when it's capped. Letting SwiftUI size the window instead
        // crashed once the content grew taller than the screen: AppKit clamped the window,
        // SwiftUI asked to grow again, and AppKit aborted the update-constraints loop.
        let hosting = NSHostingView(rootView: PreferencesView(
            viewModel: viewModel, batteryViewModel: batteryViewModel, tabState: tabState))
        hosting.sizingOptions = []
        // In a plain container: a window whose content is the SwiftUI view itself resets the
        // minimum size to zero as soon as it's shown.
        let container = NSViewController()
        container.view = NSView(frame: NSRect(origin: .zero, size: Self.minimumSize))
        hosting.frame = container.view.bounds
        hosting.autoresizingMask = [.width, .height]
        container.view.addSubview(hosting)

        let window = NSWindow(contentViewController: container)
        window.title = "\(AppInfo.shortName) Settings"
        // Resizable as well as scrolling: drag it bigger to see more of a tab at once.
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        window.delegate = self
        // @Published reports the new tab before it is stored; fit on the next turn.
        tabObserver = tabState.$tab.dropFirst().receive(on: RunLoop.main).sink { [weak self] tab in
            self?.fit(tab, animate: true)
        }
        return window
    }

    /// Resizes the window to `tab`'s natural height, no taller than the screen, keeping its
    /// top edge where it is. Once the user has dragged the window to a size, every tab opens
    /// at that size instead (still capped to the screen), and scrolls when it holds more.
    private func fit(_ tab: PreferencesTab, animate: Bool) {
        guard let window else { return }
        let screen = window.screen ?? NSScreen.main
        let available = max((screen?.visibleFrame.height ?? 800) - 80, Self.minimumSize.height)
        var size: NSSize
        if let chosen = Self.chosenSize {
            size = NSSize(width: max(chosen.width, Self.minimumSize.width),
                          height: min(max(chosen.height, Self.minimumSize.height), available))
        } else {
            let measure = PreferencesView(viewModel: viewModel, batteryViewModel: batteryViewModel, tabState: tabState)
                .measuring(tab)
            let natural = ceil(NSHostingView(rootView: measure).fittingSize.height)
            size = NSSize(width: Self.width, height: min(max(natural, Self.minimumSize.height), available))
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    /// A size the user dragged to is kept for every tab, and next time.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        Self.chosenSize = window.contentRect(forFrameRect: window.frame).size
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.refreshText()
    }
}
