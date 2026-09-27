import AppKit
import SwiftUI

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferencesController = PreferencesWindowController()
    private let historyViewModel = HistoryViewModel()
    /// Held so its checkmark can be refreshed on open; the menu itself is
    /// built once because the charts item hosts a live SwiftUI view.
    private var launchUpdateCheckItem: NSMenuItem?
    /// Held for the same reason: its title changes once the launch check has
    /// found a release waiting.
    private var updateItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.title = MetricsStore.shared.menuBarText
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        buildMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metricsDidUpdate),
            name: MetricsStore.didUpdateNotification,
            object: nil
        )
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let chartsItem = NSMenuItem()
        let hostingView = NSHostingView(rootView: MenuChartsView(viewModel: historyViewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: hostingView.fittingSize.height)
        chartsItem.view = hostingView
        menu.addItem(chartsItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        let updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.toolTip = "Download and install the latest release from GitHub, then restart."
        self.updateItem = updateItem

        let autoUpdateItem = menu.addItem(withTitle: "Check for Updates at Launch", action: #selector(toggleLaunchUpdateCheck), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = UpdateSettings.checkForUpdatesAtLaunch ? .on : .off
        autoUpdateItem.toolTip = "Look for a newer release shortly after the app opens. You are only asked if one is found."
        launchUpdateCheckItem = autoUpdateItem

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.shortName)", action: #selector(quit), keyEquivalent: "q")
            .target = self

        // Version last, as a non-actionable footer.
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "\(AppInfo.shortName) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        historyViewModel.refresh()
        // Opens with the last-known totals; the view model refreshes again when
        // this read of the other Macs' files lands.
        CloudSync.shared.refreshRemote()
        launchUpdateCheckItem?.state = UpdateSettings.checkForUpdatesAtLaunch ? .on : .off

        // A release found by the launch check is offered here rather than prompted
        // for, so an install only ever follows a click the user made.
        if let pending = UpdateAvailability.shared.pending {
            updateItem?.title = "Update to \(pending)…"
            updateItem?.toolTip = "A newer release is available. Downloading and installing it needs your confirmation."
        } else {
            updateItem?.title = "Check for Updates…"
            updateItem?.toolTip = "Download and install the latest release from GitHub, then restart."
        }
    }

    @objc private func metricsDidUpdate() {
        statusItem.button?.title = MetricsStore.shared.menuBarText
    }

    @objc private func openPreferences() {
        preferencesController.show()
    }

    @objc private func checkForUpdates() {
        UpdateController.checkForUpdates()
    }

    @objc private func toggleLaunchUpdateCheck() {
        UpdateSettings.checkForUpdatesAtLaunch.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
