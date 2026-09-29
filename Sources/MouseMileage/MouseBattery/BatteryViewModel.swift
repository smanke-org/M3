import Combine
import Foundation

/// Feeds the menu's Battery card and the Battery tab in Preferences.
final class BatteryViewModel: ObservableObject {
    struct Mouse: Identifiable, Equatable {
        var history: MouseChargeHistory
        /// Nil when the mouse isn't connected to this Mac right now.
        var connected: MouseBatteryMonitor.ConnectedMouse?

        /// The nickname, or the model with an ID suffix when needed to tell it
        /// from an identical mouse. Set by `refresh`, which sees every mouse.
        var label = ""

        var id: String { history.key }
        /// The model name.
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
    private var refreshScheduled = false

    init() {
        refresh()
        for name in [MouseBatteryMonitor.didChangeNotification, ChargeStore.didUpdateNotification, CloudSync.didUpdateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        // Distance grows with every mouse move, which is far more often than
        // the numbers need redrawing: follow it at most once a second.
        observers.append(NotificationCenter.default.addObserver(
            forName: MetricsStore.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        })
    }

    private func scheduleRefresh() {
        guard isEnabled, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
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
        var mice = histories.map { Mouse(history: $0, connected: monitor.connected[$0.key]) }
        let labels = Self.labels(for: mice.map { ($0.id, $0.name, $0.history.nickname, $0.history.idSuffix) })
        for index in mice.indices { mice[index].label = labels[mice[index].id] ?? mice[index].name }
        self.mice = mice.sorted { ($0.connected != nil ? 0 : 1, $0.label) < ($1.connected != nil ? 0 : 1, $1.label) }
    }

    /// Nickname if set; otherwise the model, plus " · ABCD" when another
    /// unnamed mouse shares that model name.
    static func labels(for mice: [(key: String, model: String, nickname: String?, suffix: String)]) -> [String: String] {
        let unnamed = mice.filter { $0.nickname == nil }
        let modelCounts = Dictionary(grouping: unnamed, by: \.model).mapValues(\.count)
        var labels: [String: String] = [:]
        for mouse in mice {
            if let nickname = mouse.nickname {
                labels[mouse.key] = nickname
            } else if (modelCounts[mouse.model] ?? 0) > 1 {
                labels[mouse.key] = "\(mouse.model) · \(mouse.suffix)"
            } else {
                labels[mouse.key] = mouse.model
            }
        }
        return labels
    }

    /// Names a mouse (or with an empty name, goes back to its model name),
    /// on every Mac.
    func rename(_ mouse: Mouse, to nickname: String?) {
        ChargeStore.shared.rename(mouse: mouse.id, model: mouse.name, to: nickname)
        CloudSync.shared.publishNow()
        refresh()
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
