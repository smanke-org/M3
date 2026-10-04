import AppKit
import SwiftUI

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let preferencesController = PreferencesWindowController()
    private let historyViewModel = HistoryViewModel()
    private let batteryViewModel = BatteryViewModel()
    private lazy var chartWindow = ChartWindowController(viewModel: historyViewModel)
    private var chartsItem: NSMenuItem?
    /// "More Charts ▸": a submenu holding one view with the flyout's cards.
    private var flyoutItem: NSMenuItem?
    private let flyoutMenu = NSMenu()
    /// The card lists the views were built with. Hosting views are measured
    /// once, so they're rebuilt (only) when this changes.
    private var builtLayout: Layout?

    private struct Layout: Equatable {
        var menu: [MenuCard]
        var flyout: [MenuCard]

        static var current: Layout {
            let battery = MouseBatteryMonitor.shared.isEnabled
            return Layout(menu: MenuCard.visible(in: MenuLayoutSettings.menuCards, batteryEnabled: battery),
                          flyout: MenuCard.visible(in: MenuLayoutSettings.flyoutCards, batteryEnabled: battery))
        }
    }
    /// Held so its checkmark can be refreshed on open; the menu itself is
    /// built once because the charts item hosts a live SwiftUI view.
    private var launchUpdateCheckItem: NSMenuItem?
    /// Held for the same reason: its title changes once the launch check has
    /// found a release waiting.
    private var updateItem: NSMenuItem?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        updateTitle()

        buildMenu()

        // The title follows this Mac's counting, the other Macs' synced totals
        // when it shows All Macs, and the setting choosing between them.
        for name in [MetricsStore.didUpdateNotification, CloudSync.didUpdateNotification, MenuBarSettings.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateTitle), name: name, object: nil)
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let chartsItem = NSMenuItem()
        self.chartsItem = chartsItem
        menu.addItem(chartsItem)

        let flyoutItem = NSMenuItem(title: "More Charts", action: nil, keyEquivalent: "")
        flyoutMenu.delegate = self
        flyoutMenu.addItem(NSMenuItem())
        flyoutItem.submenu = flyoutMenu
        self.flyoutItem = flyoutItem
        menu.addItem(flyoutItem)
        installChartsViews()

        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        let updateItem = menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.toolTip = "Download and install the latest release from GitHub, then restart."
        self.updateItem = updateItem

        let autoUpdateItem = menu.addItem(withTitle: "Check for Updates at Launch", action: #selector(toggleLaunchUpdateCheck), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = UpdateSettings.checkForUpdatesAtLaunch ? .on : .off
        autoUpdateItem.toolTip = "Look for a newer release shortly after the app opens. You are only asked if one is found."
        launchUpdateCheckItem = autoUpdateItem

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppInfo.shortName)", action: #selector(quit), keyEquivalent: "q")
            .target = self

        // Version last, as a non-actionable footer.
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "\(AppInfo.shortName) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        statusItem.menu = menu
    }

    /// A fresh hosting view measures its height from the current content, so
    /// the views are rebuilt when the chosen cards (or the Battery card) change.
    private func installChartsViews() {
        let layout = Layout.current
        chartsItem?.view = hostingView(MenuChartsView(viewModel: historyViewModel, batteryViewModel: batteryViewModel,
                                                      cards: layout.menu, onExpandChart: { [weak self] in self?.expand($0) }))

        // Two columns once there are several cards, so the flyout fits a laptop screen too.
        let columns = layout.flyout.count >= 4 ? 2 : 1
        flyoutMenu.items.first?.view = hostingView(MenuChartsView(viewModel: historyViewModel, batteryViewModel: batteryViewModel,
                                                                  cards: layout.flyout, showsTotals: false, columns: columns,
                                                                  onExpandChart: { [weak self] in self?.expand($0) }))
        flyoutItem?.isHidden = layout.flyout.isEmpty
        builtLayout = layout
    }

    /// A chart clicked in the menu or flyout: close the menu, then open the
    /// chart in its window. Opened on the next turn, once the menu has gone.
    private func expand(_ card: MenuCard) {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.chartWindow.show(card)
        }
    }

    private func hostingView(_ view: MenuChartsView) -> NSView {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: MenuChartsView.width(columns: view.columns),
                                   height: hostingView.fittingSize.height)
        return hostingView
    }

    func menuWillOpen(_ menu: NSMenu) {
        historyViewModel.refresh()
        batteryViewModel.refresh()
        // Opening the flyout only refreshes its data; its view was built, and
        // the rest of the menu updated, when the main menu opened.
        guard menu !== flyoutMenu else { return }
        if builtLayout != Layout.current {
            installChartsViews()
        }
        // Opens with the last-known totals; the view model refreshes again when
        // this read of the other Macs' files lands.
        CloudSync.shared.refreshRemote()
        launchUpdateCheckItem?.state = UpdateSettings.checkForUpdatesAtLaunch ? .on : .off

        // A release found by the launch check is offered here rather than prompted
        // for, so an install only ever follows a click the user made.
        if let pending = UpdateAvailability.shared.pending {
            updateItem?.title = "Update to \(pending)…"
            updateItem?.toolTip = "A newer release is available. Downloading and installing it needs your confirmation."
        } else {
            updateItem?.title = "Check for Updates…"
            updateItem?.toolTip = "Download and install the latest release from GitHub, then restart."
        }
    }

    /// Runs on every mouse move, so it only sums a handful of cached totals.
    @objc private func updateTitle() {
        let sync = CloudSync.shared
        statusItem.button?.title = MenuBarSettings.title(
            showsAllMacs: MenuBarSettings.showsAllMacs,
            marksAllMacs: MenuBarSettings.marksAllMacs,
            isSyncAvailable: sync.isAvailable,
            thisMacPoints: MetricsStore.shared.totalPoints,
            allMacsPoints: sync.allMacsPoints
        )
    }

    @objc func openPreferences() {
        preferencesController.show()
    }

    @objc private func checkForUpdates() {
        UpdateController.checkForUpdates()
    }

    @objc private func toggleLaunchUpdateCheck() {
        UpdateSettings.checkForUpdatesAtLaunch.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
