import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let eventMonitor = EventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything starts counting: MetricsStore records when tracking began
        // on the very first launch, so its absence means a brand-new install.
        let newInstall = UserDefaults.standard.object(forKey: "trackingStartedAt") == nil

        // A menu bar app; it has a Dock icon only if the user turned one on.
        NSApp.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.shortName, settingsTitle: "Settings…",
                                            target: self, settings: #selector(openPreferences))
        // Right below About in the app menu.
        let otherApps = NSMenuItem(title: "Our other apps…", action: #selector(showOtherApps), keyEquivalent: "")
        otherApps.target = self
        mainMenu.items.first?.submenu?.insertItem(otherApps, at: 1)
        NSApp.mainMenu = mainMenu
        AppAppearance.start()

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

        // Settings sync (separate from the totals): a new Mac picks up the user's settings.
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()

        AutoUpdater.shared.start()
    }

    /// The Dock icon's right-click menu, when "Show in Dock" is on.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(openPreferences))
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

    /// `m3tracker://today`, `by-day` and `year` (from ToolHUD, Shortcuts or a script) open
    /// that chart in its window; `m3tracker://settings` opens Settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "m3tracker" {
            switch url.host {
            case "today": statusItemController?.showChart(.todayByHour)
            case "by-day": statusItemController?.showChart(.byDay)
            case "year": statusItemController?.showChart(.yearToDate)
            default: openPreferences()
            }
        }
    }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
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
