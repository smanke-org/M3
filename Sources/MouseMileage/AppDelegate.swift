import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let eventMonitor = EventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only app, no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        UpdateSettings.registerDefaults()
        MenuBarSettings.registerDefaults()

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
