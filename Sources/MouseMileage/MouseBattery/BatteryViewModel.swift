import Combine
import Foundation

/// Feeds the menu's Battery card and the Battery tab in Preferences.
final class BatteryViewModel: ObservableObject {
    struct Mouse: Identifiable, Equatable {
        var history: MouseChargeHistory
        /// Nil when the mouse isn't connected to this Mac right now.
        var connected: MouseBatteryMonitor.ConnectedMouse?

        var id: String { history.key }
        var name: String { connected?.name ?? history.name }
        /// Live when connected, otherwise the last reading from any Mac.
        var percent: Int? { connected?.battery?.percent ?? history.latest?.percent }
        var isCharging: Bool { connected?.battery?.isCharging ?? history.latest?.isCharging ?? false }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var status: MouseBatteryMonitor.Status = .off
    /// Connected mice first, then others by name.
    @Published private(set) var mice: [Mouse] = []
    @Published var selectedKey: String?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        for name in [MouseBatteryMonitor.didChangeNotification, ChargeStore.didUpdateNotification, CloudSync.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var selected: Mouse? {
        mice.first { $0.id == selectedKey } ?? mice.first
    }

    func refresh() {
        let monitor = MouseBatteryMonitor.shared
        isEnabled = monitor.isEnabled
        status = monitor.status
        let histories = CloudSync.shared.mouseHistories
        mice = histories
            .map { Mouse(history: $0, connected: monitor.connected[$0.key]) }
            .sorted { ($0.connected != nil ? 0 : 1, $0.name) < ($1.connected != nil ? 0 : 1, $1.name) }
    }

    func setEnabled(_ enabled: Bool) {
        MouseBatteryMonitor.shared.setEnabled(enabled)
        refresh()
    }

    func resetHistory(for key: String) {
        ChargeStore.shared.resetHistory(mouse: key)
        CloudSync.shared.publishNow()
        refresh()
    }

    // MARK: - Text

    static func distance(_ charge: Charge) -> String {
        MetricsStore.distanceText(forPoints: charge.points)
    }

    static func miles(_ miles: Double) -> String {
        "\(MetricsFormatter.tenths(miles)) mi"
    }

    /// "18% used"
    static func used(_ charge: Charge) -> String {
        "\(charge.usedPercent)% used"
    }

    /// The estimate, or why there isn't one yet.
    static func perFullCharge(_ charge: Charge) -> String {
        if let value = charge.milesPerFullCharge { return "≈ \(miles(value)) per full charge" }
        return "Full-charge estimate after \(Charge.minimumUsedPercent)% used"
    }

    static func batterySymbol(percent: Int?, isCharging: Bool) -> String {
        if isCharging { return "battery.100.bolt" }
        guard let percent else { return "battery.0" }
        switch percent {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    static var statusMessage: [MouseBatteryMonitor.Status: String] {
        [
            .needsPermission: "Needs Input Monitoring permission. Open Preferences › Battery.",
            .needsRelaunch: "Quit and reopen M3 Tracker to finish turning this on.",
        ]
    }
}
