import ApplicationServices
import Combine
import Foundation

final class PreferencesViewModel: ObservableObject {
    @Published var mileageText: String = ""
    @Published var keystrokesText: String = ""
    @Published var clicksText: String = ""
    @Published var trackingSinceText: String = ""

    /// One row per Mac contributing to the All Macs total, this Mac first.
    struct MacRow: Identifiable {
        let id: String
        let name: String
        let distance: String
        let status: String
    }
    @Published var macRows: [MacRow] = []
    @Published var allMacsText: String = ""
    @Published var isSyncAvailable = false

    /// Every app, ranked by mileage. The full list behind the menu's Top Apps card.
    @Published var appRows: [AppRanking.Row] = []
    @Published var appRange: AppUsageRange = .allTime {
        didSet { refreshApps() }
    }
    /// `refreshText` runs on every mouse move; ranking every app that often is
    /// wasted work, so the list refreshes at most this often from that path.
    private var lastAppsRefresh = Date.distantPast

    private static let syncedFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let startedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    @Published var launchAtLoginEnabled: Bool
    @Published var launchAtLoginError: String?
    @Published var checkForUpdatesAtLaunch: Bool {
        didSet { UpdateSettings.checkForUpdatesAtLaunch = checkForUpdatesAtLaunch }
    }
    @Published var menuBarShowsAllMacs: Bool {
        didSet { MenuBarSettings.showsAllMacs = menuBarShowsAllMacs }
    }
    @Published var menuBarMarksAllMacs: Bool {
        didSet { MenuBarSettings.marksAllMacs = menuBarMarksAllMacs }
    }
    /// Keystrokes are only delivered to a global monitor when the app is
    /// trusted for Accessibility; without it they silently never arrive.
    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    private var metricsObserver: NSObjectProtocol?
    private var syncObserver: NSObjectProtocol?
    /// Looked up once rather than in `refreshText`, which runs on every mouse move.
    private var thisMacName = DeviceIdentity.deviceName

    init() {
        launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        checkForUpdatesAtLaunch = UpdateSettings.checkForUpdatesAtLaunch
        menuBarShowsAllMacs = MenuBarSettings.showsAllMacs
        menuBarMarksAllMacs = MenuBarSettings.marksAllMacs
        refreshText()

        metricsObserver = NotificationCenter.default.addObserver(
            forName: MetricsStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshText()
        }
        syncObserver = NotificationCenter.default.addObserver(
            forName: CloudSync.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshText()
        }
    }

    deinit {
        if let metricsObserver {
            NotificationCenter.default.removeObserver(metricsObserver)
        }
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
    }

    func refreshText() {
        let store = MetricsStore.shared
        mileageText = "\(MetricsFormatter.hundredths(store.totalMiles)) mi (\(MetricsFormatter.tenths(store.totalFeet)) ft)"
        keystrokesText = MetricsFormatter.count(store.keystrokes)
        clicksText = "Left: \(MetricsFormatter.count(store.leftClicks))   Right: \(MetricsFormatter.count(store.rightClicks))"

        let started = store.trackingStartedAt
        let days = Calendar.current.dateComponents([.day], from: started, to: Date()).day ?? 0
        let span = days == 0 ? "today" : (days == 1 ? "1 day" : "\(MetricsFormatter.count(days)) days")
        trackingSinceText = "\(Self.startedFormatter.string(from: started)) (\(span))"

        refreshMacs()
        if Date().timeIntervalSince(lastAppsRefresh) > 2 {
            refreshApps()
        }
    }

    func refreshApps() {
        lastAppsRefresh = Date()
        appRows = AppUsageStore.ranking(range: appRange, snapshots: CloudSync.shared.appSnapshots,
                                        calendar: AppUsageStore.shared.localCalendar).rows
    }

    private func refreshMacs() {
        let sync = CloudSync.shared
        isSyncAvailable = sync.isAvailable
        allMacsText = MetricsStore.distanceText(forPoints: sync.allMacsPoints)

        let thisMac = MacRow(
            id: DeviceIdentity.deviceID,
            name: thisMacName,
            distance: MetricsStore.shared.menuBarText,
            status: "This Mac"
        )
        let others = sync.remoteRecords.values
            .sorted { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }
            .map { record in
                MacRow(
                    id: record.deviceID,
                    name: record.deviceName,
                    distance: MetricsStore.distanceText(forPoints: record.totalPoints),
                    status: "Synced \(Self.syncedFormatter.localizedString(for: record.updatedAt, relativeTo: Date()))"
                )
            }
        macRows = [thisMac] + others
    }

    /// Picks up changes made elsewhere (the menu bar toggle, or System
    /// Settings for the login item) when the window is reopened.
    func refreshSettings() {
        launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        isAccessibilityTrusted = AXIsProcessTrusted()
        thisMacName = DeviceIdentity.deviceName
        refreshApps()
        if checkForUpdatesAtLaunch != UpdateSettings.checkForUpdatesAtLaunch {
            checkForUpdatesAtLaunch = UpdateSettings.checkForUpdatesAtLaunch
        }
        if menuBarShowsAllMacs != MenuBarSettings.showsAllMacs {
            menuBarShowsAllMacs = MenuBarSettings.showsAllMacs
        }
        if menuBarMarksAllMacs != MenuBarSettings.marksAllMacs {
            menuBarMarksAllMacs = MenuBarSettings.marksAllMacs
        }
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        let succeeded = LaunchAtLoginController.setEnabled(enabled)
        if succeeded {
            launchAtLoginEnabled = enabled
            launchAtLoginError = nil
        } else {
            launchAtLoginEnabled = LaunchAtLoginController.isEnabled
            launchAtLoginError = "Couldn't update Launch at Login. This requires M3 to be running from an installed app in /Applications."
        }
    }

    func openAccessibilitySettings() {
        EventMonitor.openAccessibilitySettings()
    }

    func resetMileage() {
        MetricsStore.shared.resetMileage()
    }

    func resetKeystrokes() {
        MetricsStore.shared.resetKeystrokes()
    }

    func resetClicks() {
        MetricsStore.shared.resetClicks()
    }

    func resetAll() {
        MetricsStore.shared.resetAll()
    }
}
