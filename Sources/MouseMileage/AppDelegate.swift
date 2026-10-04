import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let eventMonitor = EventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app; it has a Dock icon only if the user turned one on.
        NSApp.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
        NSApp.mainMenu = AppPresence.mainMenu(appName: AppInfo.shortName, settingsTitle: "Preferences…",
                                              target: self, settings: #selector(openPreferences))

        UpdateSettings.registerDefaults()
        MenuBarSettings.registerDefaults()
        MenuLayoutSettings.registerDefaults()

        statusItemController = StatusItemController()

        // Follow the focused app before events start arriving, so the first
        // movement is credited to the right app rather than "unknown".
        AppUsageStore.shared.start()

        eventMonitor.requestPermissionIfNeeded()
        eventMonitor.start()

        // Mileage per battery charge, if the user has turned it on.
        MouseBatteryMonitor.shared.startIfEnabled()

        // Shares this Mac's totals with the user's other Macs via iCloud Drive.
        CloudSync.shared.start()

        scheduleLaunchUpdateCheck()
    }

    /// The Dock icon's right-click menu, when "Show in Dock" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Preferences…", target: self, action: #selector(openPreferences))
    }

    /// Clicking the Dock icon, or opening the app again from Applications or
    /// Spotlight, opens Preferences — the way back when both icons are hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return true
    }

    @objc func openPreferences() {
        statusItemController?.openPreferences()
    }

    /// Looks for a newer release shortly after launch rather than during it,
    /// so startup isn't waiting on the network. Silent unless there is
    /// something to offer.
    private func scheduleLaunchUpdateCheck() {
        guard UpdateSettings.checkForUpdatesAtLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            UpdateController.checkForUpdates(silent: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MetricsStore.shared.saveIfNeeded()
        MileageHistoryStore.shared.saveIfNeeded()
        AppUsageStore.shared.saveIfNeeded()
        ChargeStore.shared.saveIfNeeded()
        CloudSync.shared.publishNow(synchronously: true)
        eventMonitor.stop()
    }
}
