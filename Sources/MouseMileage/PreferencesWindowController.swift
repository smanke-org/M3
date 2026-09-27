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
        let hostingController = NSHostingController(rootView: PreferencesView(viewModel: viewModel, batteryViewModel: batteryViewModel))
        // The window follows each tab's height.
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(AppInfo.shortName) Preferences"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.refreshText()
    }
}
