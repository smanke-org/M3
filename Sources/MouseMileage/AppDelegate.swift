import AppKit

/// "Ask before quitting" (Settings › General, on by default, synced), and quitting without
/// asking when M3 Tracker quits itself (installing an update, ending a test). Main thread only.
enum QuitConfirmation {
    static let key = "confirmQuit"
    private(set) static var confirmed = false

    static var isOn: Bool {
        get { AppDefaults.store.object(forKey: key) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: key) }
    }

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let eventMonitor = EventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything starts counting: MetricsStore records when tracking began
        // on the very first launch, so its absence means a brand-new install.
        let newInstall = AppDefaults.store.object(forKey: "trackingStartedAt") == nil

        // A menu bar app; it has a Dock icon only if the user turned one on.
        NSApp.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.shortName, settingsTitle: "Settings…",
                                            target: self, settings: #selector(openPreferences))
        // Right below About in the app menu.
        let otherApps = NSMenuItem(title: "Our other apps…", action: #selector(showOtherApps), keyEquivalent: "")
        otherApps.target = self
        mainMenu.items.first?.submenu?.insertItem(otherApps, at: 1)
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let helpOpen = NSMenuItem(title: "M3 Tracker Help", action: #selector(showHelp), keyEquivalent: "?")
        helpOpen.target = self
        help.addItem(helpOpen)
        helpItem.submenu = help
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = help
        NSApp.mainMenu = mainMenu

        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own counts and settings (AppDefaults),
        // its own sync folder inside APP_STORE, and the agent socket. Nothing else starts: no
        // event monitor or permission request, menu bar item, ToolHUD menu hub, battery
        // tracking, iCloud Drive sync, settings sync, updater or windows.
        if AgentSocket.isTestRun {
            MenuBarSettings.registerDefaults()
            _ = MetricsStore.shared
            _ = AppUsageStore.shared
            _ = ChargeStore.shared
            // Reads only the test folder's device files (APP_STORE/Devices), once.
            CloudSync.shared.refreshRemote()
            AgentSocket.listen { AgentRouter.handle($0) }
            return
        }
        #endif
        AppAppearance.start()

        #if DEBUG
        if let how = ProcessInfo.processInfo.environment["M3_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        // A test run shares the installed app's settings, so it checks Help and stops
        // before sync or anything else starts.
        if let snapshot = ProcessInfo.processInfo.environment["M3_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: nil)
            return
        }
        // The update prompt, What's New and Settings drawn to PNGs; starts nothing else
        // (no counting, permission request, sync or updater).
        if let folder = ProcessInfo.processInfo.environment["M3_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
        UpdateSettings.registerDefaults()
        MenuBarSettings.registerDefaults()
        MenuLayoutSettings.registerDefaults()

        statusItemController = StatusItemController()

        // `m3` and the MCP server talk to the app through this.
        AgentSocket.listen { AgentRouter.handle($0) }

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

        AutoUpdater.shared.start(newInstall: newInstall)
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

    @MainActor @objc func showHelp() { HelpWindow.shared.show() }

    @objc func openPreferences() {
        statusItemController?.openPreferences()
    }

    /// False in an agent CLI test copy, which has no menu bar item and opens no windows.
    var showsWindows: Bool { statusItemController != nil }

    /// `m3 charts open`: what the m3tracker:// chart links do.
    func showChart(_ card: MenuCard) {
        statusItemController?.showChart(card)
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

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when M3 Tracker quits itself to install an update.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard QuitConfirmation.isOn, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.shortName)?"
        alert.informativeText = "Mileage, clicks and keystrokes aren't counted until you open \(AppInfo.shortName) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { QuitConfirmation.isOn = false }
        return .terminateNow
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
