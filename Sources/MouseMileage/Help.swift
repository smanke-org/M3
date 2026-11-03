import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// M3 Tracker has no shortcuts the user sets, so nothing needs swapping.
    static func resolve(_ text: String) -> String { text }
    static var debugTokens: String { "" }
    static let testTabs = ["general", "menu", "apps", "battery", "sync"]

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "menu": "menu"
        case "apps": "apps"
        case "battery": "battery"
        case "sync": "all-macs"
        default: "getting-started"
        }
    }

    static func topic(for tab: PreferencesTab) -> String { topic(forSettingsTab: "\(tab)") }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("M3 Tracker counts how far your mouse and trackpad pointer travels, how far you scroll, and how many keys you press and clicks you make. The menu bar shows today's mileage; click it for charts."),
            .heading("Permission"),
            .text("To see keystrokes typed in other apps, M3 Tracker needs Accessibility permission (macOS 27 calls it Device Control). Without it, pointer mileage is still counted, and Settings › General shows a warning with a button to fix it."),
            .text("Only counts are kept: M3 Tracker never records which keys you press or what you type."),
            .tip("Settings › General shows the totals for this Mac and when tracking began."),
            .tip("While ToolHUD is running, M3 Tracker's menu, charts included, moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
            .tip("Quitting asks first, since nothing is counted while M3 Tracker is closed. Turn off \"Ask before quitting\" in Settings › General, or tick \"Don't ask again\" when it asks."),
        ]),

        HelpTopic(id: "menu", title: "The Menu and Charts", symbol: "chart.bar", blocks: [
            .text("Click the menu bar icon for cards with charts. Settings › Menu chooses which cards appear in the menu itself and which go in the More Charts submenu, so the menu stays short on a laptop screen."),
            .keys([
                ("Top Apps", "Which apps you moved the pointer and typed in most"),
                ("Mileage per Charge", "How far the mouse went on each battery charge"),
                ("Today by Hour", "Today's mileage, hour by hour"),
                ("By Day", "Mileage for each recent day"),
                ("Year to Date", "This year so far"),
            ]),
            .text("Settings › Menu also chooses whether the menu bar shows this Mac or all your Macs, and can mark the All Macs total so you can tell them apart."),
        ]),

        HelpTopic(id: "apps", title: "Apps", symbol: "square.grid.2x2", blocks: [
            .text("Settings › Apps lists the mileage, scrolling, clicks and keystrokes credited to each app, for the range you pick. The Top Apps card in the menu shows the leaders."),
        ]),

        HelpTopic(id: "battery", title: "Mouse Battery", symbol: "battery.75", blocks: [
            .text("With a Logitech mouse or an Apple Magic Mouse, M3 Tracker reads its battery level and shows how far the mouse travels on each charge, and whether that's going up or down over time. This mileage is kept separate from your other mileage and combined across your Macs through iCloud Drive."),
            .text("A new charge starts when the mouse is unplugged from charging. Turn on the low-battery warning in Settings › Battery to be told before it runs out. Reading the battery needs Input Monitoring permission, which also tells the mouse's movement apart from the trackpad's."),
        ]),

        HelpTopic(id: "all-macs", title: "All Your Macs", symbol: "laptopcomputer.and.iphone", blocks: [
            .text("With iCloud Drive on, each Mac writes its totals to iCloud Drive › M3 Tracker, and every Mac shows the combined All Macs mileage. Deleting a Mac's file there removes it from the total."),
            .text("Settings › Sync & Updates can also sync your choices (menu bar, cards, app list, low-battery warnings, where M3 appears, asking before quitting, updates) with your other Macs, and chooses how updates arrive."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("m3tracker://today", "Open the Today by Hour chart"),
                ("m3tracker://by-day", "Open the By Day chart"),
                ("m3tracker://year", "Open the Year to Date chart"),
                ("m3tracker://settings", "Open Settings"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's M3 Tracker buttons use them."),
            .heading("Command line and AI agents"),
            .text("M3 Tracker is also a command line tool, so scripts and AI agents such as Claude Code or Codex can read your totals, charts, per-app numbers and mouse battery mileage, for this Mac and all your Macs. Commands run in the open app, so the menu shows any change at once. Resetting a counter or a mouse's charge history needs --yes."),
            .keys([
                ("m3 help", "List every command and its options"),
                ("m3 totals show", "This Mac's and All Macs' distance, scrolling, clicks and keystrokes"),
                ("m3 apps list --range 7days", "Apps by distance, as Top Apps shows them"),
                ("m3 mcp", "Offer the same commands to MCP apps, such as Claude Desktop"),
            ]),
            .text("To type m3 in Terminal, link it once: ln -s \"/Applications/M3 Tracker.app/Contents/MacOS/MouseMileage\" ~/.local/bin/m3 (with ~/.local/bin on your PATH). MCP apps take the full path to that program, followed by mcp."),
        ]),

        HelpTopic(id: "updates", title: "Updates", symbol: "arrow.down.circle", blocks: [
            .text("Settings › Sync & Updates chooses what M3 Tracker does when a new version is out: install it automatically while your Mac is idle, ask you first, or not check at all. Check Now looks right away."),
            .heading("What's new"),
            .text("The update window shows the notes for the latest releases, with the ones you don't have yet marked New. \"Don't remind me about this version\" is ticked to begin with: click Not Now with it ticked, and M3 Tracker stops reminding you about that version (Check Now still offers it). Untick it to be reminded again."),
            .text("After an update that installed itself, Settings shows what changed the next time it opens. Tick \"Don't show this again\" to put it away. What's New… beside Check Now shows the notes any time, and About M3 Tracker shows the last 10 releases."),
            .tip("Settings can be dragged bigger to see more at once, and keeps the size you choose for every tab."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Keystrokes stay at zero"),
            .text("Allow M3 Tracker in System Settings › Privacy & Security › Accessibility. If it's on but nothing counts, remove it and add it again."),
            .heading("My mouse's battery doesn't show"),
            .text("Logitech mice and the Apple Magic Mouse are supported. Allow Input Monitoring, and make sure the mouse is connected to this Mac."),
            .heading("All Macs looks wrong"),
            .text("Each Mac needs iCloud Drive on and the same Apple Account. An old Mac's file in iCloud Drive › M3 Tracker still counts; delete it to drop that Mac from the total."),
        ]),
    ] }
}

// MARK: - Window

/// ObservableObject rather than @Observable, so this works on macOS 13.
@MainActor
final class HelpState: ObservableObject {
    @Published var selection: String? = "getting-started"
    @Published var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "M3 Tracker Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("M3TrackerHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @ObservedObject var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) { _ in
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "M3 Tracker Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
