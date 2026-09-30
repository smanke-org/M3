import AppKit
import SwiftUI

/// A resizable window showing one chart large, opened by clicking a chart in
/// the menu. The window picks between the three charts itself, and follows
/// new movement while it's open.
final class ChartWindowController: NSObject, NSWindowDelegate {
    private let viewModel: HistoryViewModel
    private let selection = ChartWindowSelection()
    private var window: NSWindow?
    private var refreshTimer: Timer?

    init(viewModel: HistoryViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func show(_ card: MenuCard) {
        selection.card = card
        if window == nil { window = makeWindow() }
        viewModel.refresh()
        startRefreshing()
        // Activate and order the window front together: a menu bar app asking
        // to activate with no window on screen is refused (see UpdateController).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: ChartWindowView(viewModel: viewModel, selection: selection))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(AppInfo.shortName) Charts"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 460))
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ChartWindow")
        window.delegate = self
        if window.frame.origin == .zero { window.center() }
        return window
    }

    /// The menu refreshes its charts each time it opens; an open window has
    /// to keep up on its own. Every 2 s is plenty for charts in hours and days.
    private func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.viewModel.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

/// Which chart the window shows. A class, so the controller can switch it
/// when a different chart is clicked while the window is already open.
final class ChartWindowSelection: ObservableObject {
    @Published var card: MenuCard = .todayByHour
}

private struct ChartWindowView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var selection: ChartWindowSelection

    private static let charts: [MenuCard] = [.todayByHour, .byDay, .yearToDate]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Chart", selection: $selection.card) {
                    ForEach(Self.charts) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Text(viewModel.chartsScopeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ExpandableChart(viewModel: viewModel, card: selection.card, isExpanded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
    }
}
