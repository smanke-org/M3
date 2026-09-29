import AppKit
import Charts
import SwiftUI

/// Preferences › Battery: turning the feature on, and each mouse's charges.
struct BatteryPreferencesView: View {
    @ObservedObject var viewModel: BatteryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !viewModel.isEnabled {
                intro
            } else {
                switch viewModel.status {
                case .needsPermission: permissionNeeded
                case .needsRelaunch: relaunchNeeded
                case .off, .running: EmptyView()
                }
                if viewModel.mice.isEmpty {
                    if viewModel.status == .running {
                        Text("No supported mouse found yet. Connect a Logitech mouse (Bluetooth, Bolt, or Unifying) or an Apple Magic Mouse.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    if viewModel.mice.count > 1 {
                        Picker("Mouse", selection: Binding(
                            get: { viewModel.selected?.id ?? "" },
                            set: { viewModel.selectedKey = $0 }
                        )) {
                            ForEach(viewModel.mice) { Text($0.label).tag($0.id) }
                        }
                        .fixedSize()
                    }
                    if let mouse = viewModel.selected {
                        MouseChargesView(mouse: mouse, reset: { confirmReset(mouse) }, rename: { promptRename(mouse) })
                    }
                }
                Divider()
                Button("Turn Off Mileage per Charge") { viewModel.setEnabled(false) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mileage per Charge")
                .font(.system(size: 13, weight: .semibold))
            Text("See how far your mouse travels on each battery charge, and whether that's going up or down over time. Works with Logitech mice and Apple Magic Mouse. Kept separate from your other mileage, and combined across your Macs through iCloud Drive.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Needs Input Monitoring permission, to read the mouse's battery level and tell its movement apart from the trackpad's. M3 Tracker uses it for nothing else.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On…") { viewModel.setEnabled(true) }
        }
    }

    private var permissionNeeded: some View {
        notice(title: "Waiting for Input Monitoring permission",
               detail: "Turn on M3 Tracker in System Settings › Privacy & Security › Input Monitoring. Tracking starts as soon as it's on.",
               button: "Open Input Monitoring Settings…") {
            MouseBatteryMonitor.openInputMonitoringSettings()
        }
    }

    private var relaunchNeeded: some View {
        notice(title: "Quit and reopen M3 Tracker",
               detail: "macOS applies Input Monitoring permission when an app next opens.",
               button: "Quit M3 Tracker") {
            NSApp.terminate(nil)
        }
    }

    private func notice(title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private func promptRename(_ mouse: BatteryViewModel.Mouse) {
        let alert = NSAlert()
        alert.messageText = "Rename \(mouse.label)"
        var detail = "Shown instead of \"\(mouse.name)\" on all your Macs."
        if let serial = mouse.history.serial { detail += " Serial number \(serial), printed under the mouse." }
        alert.informativeText = detail
        let field = NSTextField(string: mouse.history.nickname ?? "")
        field.placeholderString = mouse.name
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        if mouse.history.nickname != nil { alert.addButton(withTitle: "Use Model Name") }
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn: viewModel.rename(mouse, to: field.stringValue)
        case .alertThirdButtonReturn: viewModel.rename(mouse, to: nil)
        default: break
        }
    }

    private func confirmReset(_ mouse: BatteryViewModel.Mouse) {
        let alert = NSAlert()
        alert.messageText = "Reset charge history for \(mouse.label)?"
        alert.informativeText = "Clears this mouse's charges on all your Macs. Your other mileage isn't affected."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.resetHistory(for: mouse.id)
        }
    }
}

/// One mouse: its current charge, a chart of miles per full charge, and the list.
private struct MouseChargesView: View {
    let mouse: BatteryViewModel.Mouse
    let reset: () -> Void
    let rename: () -> Void

    private struct Bar: Identifiable {
        let id: Date
        let label: String
        let value: Double
        let isCurrent: Bool
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// Charges with an estimate, oldest first; the current one last, if it has one.
    private var bars: [Bar] {
        var seen: [String: Int] = [:]
        return mouse.history.charges.compactMap { charge in
            guard let value = charge.milesPerFullCharge else { return nil }
            var label = charge.isCurrent ? "Now" : Self.dateFormatter.string(from: charge.start)
            // Bars are placed by label, so two charges begun the same day need distinct ones.
            seen[label, default: 0] += 1
            if let count = seen[label], count > 1 { label += " (\(count))" }
            return Bar(id: charge.start, label: label, value: value, isCurrent: charge.isCurrent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            chart
            list
            Button("Reset Charge History…", action: reset)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mouse.label).font(.system(size: 13, weight: .semibold))
                Button(action: rename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename this mouse")
                Spacer()
                Image(systemName: BatteryViewModel.batterySymbol(percent: mouse.percent, isCharging: mouse.isCharging))
                Text(mouse.percent.map { "\($0)%\(mouse.isCharging ? ", charging" : "")" } ?? "—")
                    .monospacedDigit()
            }
            Group {
                if let charge = mouse.history.current {
                    Text("This charge: \(BatteryViewModel.distance(charge)) · \(BatteryViewModel.used(charge)) · \(BatteryViewModel.perFullCharge(charge))")
                } else if mouse.isCharging {
                    Text("Charging. A new charge starts when it's unplugged.")
                }
                if let average = mouse.history.averageMilesPerFullCharge {
                    Text("Average: \(BatteryViewModel.miles(average)) per full charge, over \(countText(mouse.history.completed.compactMap(\.milesPerFullCharge).count))")
                }
                if mouse.connected == nil {
                    Text("Not connected to this Mac. Showing the last reading.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 charge" : "\(count) charges"
    }

    @ViewBuilder
    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Miles per Full Charge")
                .font(.system(size: 12, weight: .semibold))
            if bars.isEmpty {
                Text("The chart fills in once a charge has used \(Charge.minimumUsedPercent)% of the battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Charge", bar.label), y: .value("Miles", bar.value))
                            .foregroundStyle(Color.accentColor.opacity(bar.isCurrent ? 0.35 : 0.8))
                    }
                    if let average = mouse.history.averageMilesPerFullCharge {
                        RuleMark(y: .value("Average", average))
                            .lineStyle(StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                        AxisValueLabel {
                            if let miles = value.as(Double.self) {
                                Text("\(MetricsFormatter.tenths(miles)) mi").font(.system(size: 9))
                            }
                        }
                    }
                }
                .frame(height: 130)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }

    private var list: some View {
        let completed = Array(mouse.history.completed.reversed())
        return VStack(alignment: .leading, spacing: 5) {
            if !completed.isEmpty {
                HStack(spacing: 8) {
                    Text("Charge").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Distance").frame(width: 70, alignment: .trailing)
                    Text("Used").frame(width: 44, alignment: .trailing)
                    Text("Per full").frame(width: 70, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(completed) { charge in
                            HStack(spacing: 8) {
                                Text(range(charge)).frame(maxWidth: .infinity, alignment: .leading)
                                Text(BatteryViewModel.distance(charge)).frame(width: 70, alignment: .trailing)
                                Text("\(charge.usedPercent)%").frame(width: 44, alignment: .trailing)
                                Text(charge.milesPerFullCharge.map(BatteryViewModel.miles) ?? "—")
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .monospacedDigit()
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private func range(_ charge: Charge) -> String {
        let start = Self.dateFormatter.string(from: charge.start)
        guard let end = charge.end else { return start }
        return "\(start) – \(Self.dateFormatter.string(from: end))"
    }
}
