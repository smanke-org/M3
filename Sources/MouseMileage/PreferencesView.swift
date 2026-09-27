import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statsSection
            if !viewModel.isAccessibilityTrusted {
                accessibilityWarning
            }
            Divider()
            allMacsSection
            Divider()
            settingsSection
            Divider()
            resetSection
            footer
        }
        .padding(20)
        .frame(width: 360)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mileage (this Mac): \(viewModel.mileageText)")
            Text("Keystrokes: \(viewModel.keystrokesText)")
            Text("Clicks — \(viewModel.clicksText)")
            Text("Tracking since: \(viewModel.trackingSinceText)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }

    /// Where the All Macs total comes from, so it can be explained and a Mac that
    /// has stopped syncing is easy to spot.
    private var allMacsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All Macs")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if viewModel.isSyncAvailable {
                    Text(viewModel.allMacsText)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
            }

            if viewModel.isSyncAvailable {
                ForEach(viewModel.macRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                            Text(row.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.distance).monospacedDigit()
                    }
                    .font(.system(size: 13))
                }
                Text("Synced through iCloud Drive › M3 Tracker. Deleting a Mac's file there removes it from the total.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Turn on iCloud Drive to combine mileage from all your Macs signed in to the same Apple Account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Mouse events arrive without permission but key events don't, so without
    /// this the app looks like it works while silently counting no keystrokes.
    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keystrokes in other apps aren't being counted")
                .font(.system(size: 12, weight: .semibold))
            Text("M3 Tracker needs Accessibility permission to see keystrokes typed elsewhere. Only keys pressed while this window has focus are counted right now. Mileage and clicks need no permission, which is why those still work.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Accessibility Settings…") {
                viewModel.openAccessibilitySettings()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Launch at Login", isOn: Binding(
                get: { viewModel.launchAtLoginEnabled },
                set: { viewModel.toggleLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)

            Toggle("Check for updates when the app opens", isOn: $viewModel.checkForUpdatesAtLaunch)
                .toggleStyle(.checkbox)
                .help("Looks for a newer release on GitHub a few seconds after launch. You are only asked if there is one.")

            if let error = viewModel.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Reset Mileage") { confirmAndRun("Reset mouse mileage to zero?", viewModel.resetMileage) }
            Button("Reset Keystrokes") { confirmAndRun("Reset keystroke count to zero?", viewModel.resetKeystrokes) }
            Button("Reset Clicks") { confirmAndRun("Reset left and right click counts to zero?", viewModel.resetClicks) }
            Button("Reset All") { confirmAndRun("Reset all counters (mileage, keystrokes, and clicks) to zero?", viewModel.resetAll) }
        }
    }

    private var footer: some View {
        Text("\(AppInfo.displayName) — Version \(AppInfo.version)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func confirmAndRun(_ message: String, _ action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}
