import Combine
import Foundation

/// Feeds the totals and mileage charts shown in the menu bar dropdown.
///
/// The charts combine every Mac on the iCloud account; the "This Mac" line stays
/// this Mac's own. (The menu bar title is set by `MenuBarSettings`.)
final class HistoryViewModel: ObservableObject {
    @Published var byHour: [MileageHistoryStore.Bucket] = []
    @Published var byDay: [MileageHistoryStore.Bucket] = []
    @Published var yearToDate: [MileageHistoryStore.Bucket] = []

    @Published var thisMacText = ""
    @Published var allMacsText = ""
    /// Caption naming whose data the Top Apps card and charts show.
    @Published var chartsScopeText = ""

    /// The top five apps for the chosen range, and everything else rolled up.
    @Published var topApps: [AppRanking.Row] = []
    @Published var otherAppsCount = 0
    @Published var otherAppsUsage = AppUsage()
    /// Remembered across launches.
    @Published var appRange: AppUsageRange = HistoryViewModel.savedAppRange {
        didSet {
            UserDefaults.standard.set(appRange.rawValue, forKey: Self.appRangeKey)
            refreshApps()
        }
    }

    static let topAppCount = 5
    private static let appRangeKey = "topApps.range"
    private static var savedAppRange: AppUsageRange {
        UserDefaults.standard.string(forKey: appRangeKey).flatMap(AppUsageRange.init(rawValue:)) ?? .today
    }

    private var syncObserver: NSObjectProtocol?

    init() {
        refresh()
        // A read of the other Macs' files finishes after the menu has opened;
        // refresh then, so the open menu updates rather than showing stale numbers.
        syncObserver = NotificationCenter.default.addObserver(
            forName: CloudSync.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let syncObserver { NotificationCenter.default.removeObserver(syncObserver) }
    }

    func refresh() {
        let history = MileageHistoryStore.shared
        let sync = CloudSync.shared
        let remote = sync.activeRemoteRecords

        let hourly = history.merge([history.hourlyBuckets] + remote.map(\.hourly), unit: .hour)
        let daily = history.merge([history.dailyBuckets] + remote.map(\.daily), unit: .day)
        byHour = history.todayByHour(from: hourly)
        byDay = history.last7Days(from: daily)
        yearToDate = history.yearToDate(from: daily)

        thisMacText = MetricsStore.distanceText(forPoints: MetricsStore.shared.totalPoints)

        if !sync.isAvailable {
            allMacsText = "iCloud Drive is off"
            chartsScopeText = "Apps and charts: this Mac only (iCloud Drive is off)"
        } else {
            let count = sync.macCount
            let macs = count == 1 ? "1 Mac" : "\(count) Macs"
            allMacsText = "\(MetricsStore.distanceText(forPoints: sync.allMacsPoints)) · \(macs)"
            chartsScopeText = count == 1 ? "Apps and charts: this Mac (no other Macs synced yet)" : "Apps and charts: all \(macs) combined"
        }

        refreshApps()
    }

    func refreshApps() {
        let store = AppUsageStore.shared
        let ranking = AppUsageStore.ranking(range: appRange, snapshots: CloudSync.shared.appSnapshots,
                                            calendar: store.localCalendar)
        topApps = Array(ranking.rows.prefix(Self.topAppCount))
        let rest = ranking.rows.dropFirst(Self.topAppCount)
        otherAppsCount = rest.count
        otherAppsUsage = rest.reduce(into: AppUsage()) { $0.add($1.usage) }
    }
}
