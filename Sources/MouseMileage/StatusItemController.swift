import AppKit
import SwiftUI

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferencesController = PreferencesWindowController()
    private let historyViewModel = HistoryViewModel()
    private let batteryViewModel = BatteryViewModel()
    private var chartsItem: NSMenuItem?
    /// Whether the charts view was sized with the Battery card in it.
    private var chartsIncludeBattery = false
    /// Held so its checkmark can be refreshed on open; the menu itself is
    /// built once because the charts item hosts a live SwiftUI view.
    private var launchUpdateCheckItem: NSMenuItem?
    /// Held for the same reason: its title changes once the launch check has
    /// found a release waiting.
    private var updateItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        updateTitle()

        buildMenu()

        // The title follows this Mac's counting, the other Macs' synced totals
        // when it shows All Macs, and the setting choosing between them.
        for name in [MetricsStore.didUpdateNotification, CloudSync.didUpdateNotification, MenuBarSettings.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateTitle), name: name, object: nil)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let chartsItem = NSMenuItem()
        self.chartsItem = chartsItem
        installChartsView()
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

    /// A fresh hosting view measures its height from the current content, so
    /// this is redone when the Battery card is switched on or off.
    private func installChartsView() {
        let hostingView = NSHostingView(rootView: MenuChartsView(viewModel: historyViewModel, batteryViewModel: batteryViewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: hostingView.fittingSize.height)
        chartsItem?.view = hostingView
        chartsIncludeBattery = batteryViewModel.isEnabled
    }

    func menuWillOpen(_ menu: NSMenu) {
        historyViewModel.refresh()
        batteryViewModel.refresh()
        if chartsIncludeBattery != batteryViewModel.isEnabled {
            installChartsView()
        }
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

    /// Runs on every mouse move, so it only sums a handful of cached totals.
    @objc private func updateTitle() {
        let sync = CloudSync.shared
        statusItem.button?.title = MenuBarSettings.title(
            showsAllMacs: MenuBarSettings.showsAllMacs,
            marksAllMacs: MenuBarSettings.marksAllMacs,
            isSyncAvailable: sync.isAvailable,
            thisMacPoints: MetricsStore.shared.totalPoints,
            allMacsPoints: sync.allMacsPoints
        )
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
