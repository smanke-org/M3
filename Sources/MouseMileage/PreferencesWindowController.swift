import AppKit
import Combine
import SwiftUI

final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = PreferencesViewModel()
    private let batteryViewModel = BatteryViewModel()
    private let tabState = PreferencesTabState()
    private var tabObserver: AnyCancellable?

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
        // The refreshes above can change what the tab shows (Macs, mice) a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.fit(self.tabState.tab, animate: true)
        }
    }

    private func makeWindow() -> NSWindow {
        // Sized here, to each tab's natural height capped to the screen, with the tab
        // scrolling inside when it's capped. Letting SwiftUI size the window instead
        // crashed once the content grew taller than the screen: AppKit clamped the window,
        // SwiftUI asked to grow again, and AppKit aborted the update-constraints loop.
        let hostingController = NSHostingController(rootView: PreferencesView(
            viewModel: viewModel, batteryViewModel: batteryViewModel, tabState: tabState))
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppInfo.shortName) Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // @Published reports the new tab before it is stored; fit on the next turn.
        tabObserver = tabState.$tab.dropFirst().receive(on: RunLoop.main).sink { [weak self] tab in
            self?.fit(tab, animate: true)
        }
        return window
    }

    /// Resizes the window to `tab`'s natural height, no taller than the screen, keeping
    /// its top edge where it is. The window can be made shorter (the tab then scrolls)
    /// but never taller than the tab, so there's no empty space below it.
    private func fit(_ tab: PreferencesTab, animate: Bool) {
        guard let window else { return }
        let measure = PreferencesView(viewModel: viewModel, batteryViewModel: batteryViewModel, tabState: tabState)
            .measuring(tab)
        let natural = ceil(NSHostingView(rootView: measure).fittingSize.height)
        let screen = window.screen ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 800) - 80
        let height = min(natural, available)
        window.contentMinSize = NSSize(width: 500, height: min(200, height))
        window.contentMaxSize = NSSize(width: 500, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: 500, height: height)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.refreshText()
    }
}
