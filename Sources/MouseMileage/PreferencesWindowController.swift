import AppKit
import SwiftUI

final class PreferencesWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let viewModel = PreferencesViewModel()
    private let batteryViewModel = BatteryViewModel()

    func show() {
        if window == nil {
            window = makeWindow()
        }
        viewModel.refreshText()
        viewModel.refreshSettings()
        batteryViewModel.refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = PreferencesView(viewModel: viewModel, batteryViewModel: batteryViewModel)
        // The General tab's natural height, capped to the screen, with each tab scrolling
        // inside. Letting SwiftUI size the window to the content's full height crashed once
        // it grew taller than the screen: AppKit clamped the window, SwiftUI asked to grow
        // again, and AppKit aborted the update-constraints loop.
        let natural = NSHostingView(rootView: view).fittingSize.height
        let hostingController = NSHostingController(rootView: view)
        hostingController.sizingOptions = []

        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppInfo.shortName) Settings"
        window.styleMask = [.titled, .closable, .resizable]
        let available = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        window.setContentSize(NSSize(width: 500, height: min(max(natural, 400), available)))
        window.contentMinSize = NSSize(width: 500, height: 400)
        window.contentMaxSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.refreshText()
    }
}
