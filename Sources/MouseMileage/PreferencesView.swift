import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel
    @ObservedObject var batteryViewModel: BatteryViewModel

    // Tabs, because one page holding the apps list and the charge chart as
    // well would be taller than a laptop screen.
    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            page { menuSection }
                .tabItem { Label("Menu", systemImage: "menubar.rectangle") }
            page { appsSection }
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            page { BatteryPreferencesView(viewModel: batteryViewModel) }
                .tabItem { Label("Battery", systemImage: "battery.75") }
        }
        .padding(12)
        .frame(width: 500)
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var general: some View {
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
        .padding(16)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mileage (this Mac): \(viewModel.mileageText)")
            Text("Scrolled (this Mac): \(viewModel.scrolledText)")
            Text("Keystrokes: \(viewModel.keystrokesText)")
            Text("Clicks — \(viewModel.clicksText)")
            Text("Tracking since: \(viewModel.trackingSinceText)")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }

    /// Every app's mileage, clicks, and keystrokes — the full list behind the
    /// menu's Top Apps card. Capped in height so the window stays a sensible size.
    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apps")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("Range", selection: $viewModel.appRange) {
                    ForEach(AppUsageRange.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if viewModel.appRows.isEmpty {
                Text("No app data for this range yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    sortHeader("App", .name).frame(maxWidth: .infinity, alignment: .leading)
                    sortHeader("Distance", .distance).frame(width: 70, alignment: .trailing)
                    sortHeader("Scroll", .scroll).frame(width: 70, alignment: .trailing)
                    sortHeader("Clicks", .clicks).frame(width: 52, alignment: .trailing)
                    sortHeader("Keys", .keystrokes).frame(width: 60, alignment: .trailing)
                }
                .font(.caption)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(viewModel.sortedAppRows) { app in
                            HStack(spacing: 8) {
                                HStack(spacing: 6) {
                                    Image(nsImage: AppIcons.icon(for: app.id))
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(app.name).lineLimit(1).truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(app.name)
                                Text(MetricsStore.distanceText(forPoints: app.usage.points))
                                    .frame(width: 70, alignment: .trailing)
                                Text(MetricsStore.distanceText(forPoints: app.usage.scrollPoints))
                                    .frame(width: 70, alignment: .trailing)
                                Text(MetricsFormatter.count(app.usage.clicks))
                                    .frame(width: 52, alignment: .trailing)
                                Text(MetricsFormatter.count(app.usage.keystrokes))
                                    .frame(width: 60, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .monospacedDigit()
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    /// A column title that sorts the list by that column; clicking it again
    /// reverses the order. The sorted column shows an arrow and full contrast.
    private func sortHeader(_ title: String, _ column: AppSortColumn) -> some View {
        let isSorted = viewModel.appSort == column
        return Button {
            viewModel.sortApps(by: column)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if isSorted {
                    Image(systemName: viewModel.appSortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(isSorted ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title.lowercased())")
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

            Toggle("Show in Dock", isOn: $viewModel.showInDock)
                .toggleStyle(.checkbox)
                .help("Adds a Dock icon whose right-click menu opens Preferences.")

            Toggle("Show in menu bar", isOn: $viewModel.showInMenuBar)
                .toggleStyle(.checkbox)

            if !viewModel.showInDock && !viewModel.showInMenuBar {
                Text(AppPresence.hiddenEverywhereNote(appName: AppInfo.shortName, settingsName: "Preferences"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }


            if let error = viewModel.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The menu bar title, and which cards the dropdown and its flyout show.
    private var menuSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Menu bar shows")
                    Picker("Menu bar shows", selection: $viewModel.menuBarShowsAllMacs) {
                        Text("This Mac").tag(false)
                        Text("All Macs").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Toggle("Mark the All Macs total with \(MenuBarSettings.allMacsMarker)", isOn: $viewModel.menuBarMarksAllMacs)
                    .toggleStyle(.checkbox)
                    .disabled(!viewModel.menuBarShowsAllMacs)
                    .help("Prefixes the menu bar title with \(MenuBarSettings.allMacsMarker) while it shows all Macs, so it can't be mistaken for this Mac's mileage.")
                if viewModel.menuBarShowsAllMacs && !viewModel.isSyncAvailable {
                    Text("iCloud Drive is off, so the menu bar shows this Mac until it's back on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Cards")
                    .font(.system(size: 13, weight: .semibold))
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                        Text("Menu").font(.caption).foregroundStyle(.secondary)
                        Text("More Charts").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(MenuCard.allCases) { card in
                        GridRow {
                            Text(card.title)
                            Toggle(card.title, isOn: viewModel.binding(card, inMenu: true))
                                .labelsHidden()
                                .gridColumnAlignment(.center)
                            Toggle(card.title, isOn: viewModel.binding(card, inMenu: false))
                                .labelsHidden()
                                .gridColumnAlignment(.center)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Text("Every card in the menu makes it taller. On a laptop screen, keep one or two there so it doesn't scroll, and open the rest from More Charts. Mileage per Charge appears only while it's turned on in Battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Reset Mileage") { confirmAndRun("Reset mouse mileage to zero?", viewModel.resetMileage) }
            Button("Reset Keystrokes") { confirmAndRun("Reset keystroke count to zero?", viewModel.resetKeystrokes) }
            Button("Reset Clicks") { confirmAndRun("Reset left and right click counts to zero?", viewModel.resetClicks) }
            Button("Reset Scroll Distance") { confirmAndRun("Reset the distance scrolled to zero?", viewModel.resetScroll) }
            Button("Reset All") { confirmAndRun("Reset all counters (mileage, scrolling, keystrokes, and clicks) to zero?", viewModel.resetAll) }
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
