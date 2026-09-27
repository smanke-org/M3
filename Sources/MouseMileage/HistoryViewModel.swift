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
    /// Caption naming whose data the charts show.
    @Published var chartsScopeText = ""

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
        let remote = Array(sync.remoteRecords.values)

        let hourly = history.merge([history.hourlyBuckets] + remote.map(\.hourly), unit: .hour)
        let daily = history.merge([history.dailyBuckets] + remote.map(\.daily), unit: .day)
        byHour = history.todayByHour(from: hourly)
        byDay = history.last7Days(from: daily)
        yearToDate = history.yearToDate(from: daily)

        thisMacText = MetricsStore.distanceText(forPoints: MetricsStore.shared.totalPoints)

        if !sync.isAvailable {
            allMacsText = "iCloud Drive is off"
            chartsScopeText = "Charts: this Mac only (iCloud Drive is off)"
        } else {
            let count = sync.macCount
            let macs = count == 1 ? "1 Mac" : "\(count) Macs"
            allMacsText = "\(MetricsStore.distanceText(forPoints: sync.allMacsPoints)) · \(macs)"
            chartsScopeText = count == 1 ? "Charts: this Mac (no other Macs synced yet)" : "Charts: all \(macs) combined"
        }
    }
}
