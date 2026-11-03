import AppKit
import ApplicationServices

/// Everything an agent can do in M3 Tracker. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the menu,
/// Settings and the m3tracker:// links, so the menu and windows show each change at once.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, what the menu bar shows (`menuBarTitle`), since when this Mac has counted, whether iCloud Drive sync is on and how many Macs it combines, whether keystrokes can be counted (`accessibilityTrusted`), and whether mileage per battery charge is on.",
                     example: "m3 status --json", readOnly: true) { _ in
            let sync = CloudSync.shared
            let battery = MouseBatteryMonitor.shared
            return ["app": AppInfo.shortName, "version": AppInfo.version, "testCopy": AgentSocket.isTestRun,
                    "menuBarTitle": menuBarTitle,
                    "trackingSince": JSON.date(MetricsStore.shared.trackingStartedAt),
                    "thisMac": DeviceIdentity.deviceName,
                    "distanceThisMac": MetricsStore.distanceText(forPoints: MetricsStore.shared.totalPoints, fine: true),
                    "syncAvailable": sync.isAvailable, "macs": sync.macCount,
                    "accessibilityTrusted": AXIsProcessTrusted(),
                    "batteryTracking": battery.isEnabled, "batteryStatus": "\(battery.status)"]
        },

        // MARK: Numbers

        AgentCommand(name: "totals show", summary: "Show the totals the menu shows: pointer distance, distance scrolled, clicks and keystrokes, for This Mac and for All Macs (every Mac syncing through iCloud Drive). Returns `totals`, one row per scope.",
                     example: "m3 totals show --json", readOnly: true) { _ in
            let metrics = MetricsStore.shared
            let sync = CloudSync.shared
            let remote = Array(sync.remoteRecords.values)
            let thisMac: JSONObject = [
                "scope": "This Mac", "name": DeviceIdentity.deviceName,
                "distance": MetricsStore.distanceText(forPoints: metrics.totalPoints, fine: true), "miles": round(miles(metrics.totalPoints)),
                "scrolled": MetricsStore.distanceText(forPoints: metrics.scrollPoints, fine: true), "scrollMiles": round(miles(metrics.scrollPoints)),
                "leftClicks": metrics.leftClicks, "rightClicks": metrics.rightClicks, "keystrokes": metrics.keystrokes,
                "since": JSON.date(metrics.trackingStartedAt), "macs": 1,
            ]
            var allMacs: JSONObject = ["scope": "All Macs", "macs": sync.macCount, "available": sync.isAvailable]
            if sync.isAvailable {
                allMacs["distance"] = MetricsStore.distanceText(forPoints: sync.allMacsPoints, fine: true)
                allMacs["miles"] = round(miles(sync.allMacsPoints))
                allMacs["scrolled"] = MetricsStore.distanceText(forPoints: sync.allMacsScrollPoints, fine: true)
                allMacs["scrollMiles"] = round(miles(sync.allMacsScrollPoints))
                allMacs["leftClicks"] = metrics.leftClicks + remote.reduce(0) { $0 + $1.leftClicks }
                allMacs["rightClicks"] = metrics.rightClicks + remote.reduce(0) { $0 + $1.rightClicks }
                allMacs["keystrokes"] = metrics.keystrokes + remote.reduce(0) { $0 + $1.keystrokes }
            } else {
                allMacs["note"] = "iCloud Drive is off, so only This Mac is counted"
            }
            return ["totals": [thisMac, allMacs]]
        },
        AgentCommand(name: "history show", summary: "Show a chart's numbers: `today` (by hour, from midnight), `by-day` (the last 7 days) or `year` (each day since January 1). Pointer distance and distance scrolled per hour or day, every Mac combined as in the menu unless --this-mac. Returns `buckets` (start in UTC, local time, miles, scrollMiles) and `total`.",
                     params: [.init(name: "chart", help: "today (default), by-day or year"),
                              .init(name: "this-mac", kind: .boolean, help: "only this Mac, not every Mac combined"),
                              .init(name: "skip-empty", kind: .boolean, help: "leave out hours or days with no movement or scrolling")],
                     example: "m3 history show --chart by-day --json", readOnly: true) { args in
            let chart = try chartCard(args.string("chart") ?? "today")
            let pointer: [MileageHistoryStore.Bucket], scroll: [MileageHistoryStore.Bucket]
            if try args.bool("this-mac") == true {
                let (own, ownScroll) = (MileageHistoryStore.shared, MileageHistoryStore.scroll)
                switch chart {
                case .todayByHour: (pointer, scroll) = (own.todayByHour(), ownScroll.todayByHour())
                case .byDay: (pointer, scroll) = (own.last7Days(), ownScroll.last7Days())
                default: (pointer, scroll) = (own.yearToDate(), ownScroll.yearToDate())
                }
            } else {
                // The menu's own numbers, every Mac merged onto this Mac's calendar.
                let model = historyModel
                model.refresh()
                switch chart {
                case .todayByHour: (pointer, scroll) = (model.byHour, model.scrollByHour)
                case .byDay: (pointer, scroll) = (model.byDay, model.scrollByDay)
                default: (pointer, scroll) = (model.yearToDate, model.scrollYearToDate)
                }
            }
            let scrollByStart = Dictionary(scroll.map { ($0.start, $0.points) }, uniquingKeysWith: +)
            var buckets: [JSONObject] = []
            for bucket in pointer {
                let scrollMiles = scrollByStart[bucket.start] ?? 0
                if try args.bool("skip-empty") == true, bucket.points == 0, scrollMiles == 0 { continue }
                buckets.append(["time": localTime(bucket.start, hourly: chart == .todayByHour), "start": JSON.date(bucket.start),
                                "miles": round(bucket.points), "scrollMiles": round(scrollMiles)])
            }
            return ["chart": chart.title, "allMacs": try args.bool("this-mac") != true, "buckets": buckets, "total": buckets.count,
                    "totalMiles": round(pointer.reduce(0) { $0 + $1.points }), "totalScrollMiles": round(scroll.reduce(0) { $0 + $1.points })]
        },
        AgentCommand(name: "apps list", summary: "List apps by how far the pointer moved in them, as Top Apps and Settings › Apps do: distance, scrolling, clicks and keystrokes for each app, every Mac combined unless --this-mac. Returns `apps` (id is the bundle ID), `total` and `nextOffset` when there are more.",
                     params: [.init(name: "range", help: "today (default), 7days or all"),
                              .init(name: "sort", help: "distance (default), scroll, clicks, keystrokes or name"),
                              .init(name: "ascending", kind: .boolean, help: "smallest first (names A to Z)"),
                              .init(name: "this-mac", kind: .boolean, help: "only this Mac, not every Mac combined"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "m3 apps list --range 7days --sort clicks --limit 10 --json", readOnly: true) { args in
            let range = try appRange(args.string("range") ?? "today")
            let sortName = args.string("sort") ?? "distance"
            guard let column = AppSortColumn(rawValue: sortName.lowercased()) else {
                throw AgentError.usage("--sort must be distance, scroll, clicks, keystrokes or name, not \"\(sortName)\"")
            }
            let snapshots = try args.bool("this-mac") == true ? [AppUsageStore.shared.snapshot] : CloudSync.shared.appSnapshots
            let ranked = AppUsageStore.ranking(range: range, snapshots: snapshots, calendar: AppUsageStore.shared.localCalendar).rows
            let rows = AppSortColumn.sorted(ranked, by: column, ascending: try args.bool("ascending") == true)
            var result = try page(rows, key: "apps", args) { row -> JSONObject in
                ["id": row.id, "name": row.name,
                 "distance": MetricsStore.distanceText(forPoints: row.usage.points, fine: true), "miles": round(miles(row.usage.points)),
                 "scrolled": MetricsStore.distanceText(forPoints: row.usage.scrollPoints, fine: true), "scrollMiles": round(miles(row.usage.scrollPoints)),
                 "clicks": row.usage.clicks, "keystrokes": row.usage.keystrokes]
            }
            result["range"] = range.title
            return result
        },
        AgentCommand(name: "macs list", summary: "List the Macs whose totals make up All Macs, this Mac first, as Settings › General does: distance, scrolling, clicks, keystrokes and when each last synced. Returns `macs` and `total`.",
                     example: "m3 macs list --json", readOnly: true) { _ in
            let metrics = MetricsStore.shared
            let sync = CloudSync.shared
            var macs: [JSONObject] = [[
                "id": String(DeviceIdentity.deviceID.prefix(8)), "name": DeviceIdentity.deviceName, "thisMac": true,
                "distance": MetricsStore.distanceText(forPoints: metrics.totalPoints, fine: true), "miles": round(miles(metrics.totalPoints)),
                "scrollMiles": round(miles(metrics.scrollPoints)), "clicks": metrics.leftClicks + metrics.rightClicks,
                "keystrokes": metrics.keystrokes, "since": JSON.date(metrics.trackingStartedAt),
            ]]
            for record in sync.remoteRecords.values.sorted(by: { $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending }) {
                macs.append(["id": String(record.deviceID.prefix(8)), "name": record.deviceName, "thisMac": false,
                             "distance": MetricsStore.distanceText(forPoints: record.totalPoints, fine: true), "miles": round(miles(record.totalPoints)),
                             "scrollMiles": round(miles(record.scrollPoints ?? 0)), "clicks": record.leftClicks + record.rightClicks,
                             "keystrokes": record.keystrokes, "since": JSON.date(record.trackingStartedAt),
                             "synced": JSON.date(record.updatedAt)])
            }
            return ["macs": macs, "total": macs.count, "syncAvailable": sync.isAvailable]
        },

        // MARK: Mouse battery

        AgentCommand(name: "mice list", summary: "List the mice tracked for mileage per battery charge (Settings › Battery), from every Mac: battery level, whether it's connected here, distance on the current charge and the average per full charge. Returns `mice` (id is the mouse's key) and whether tracking is on.",
                     example: "m3 mice list --json", readOnly: true) { _ in
            let model = batteryModel
            model.refresh()
            return ["mice": model.mice.map(mouseSummary), "total": model.mice.count,
                    "trackingOn": model.isEnabled, "status": "\(model.status)"]
        },
        AgentCommand(name: "mice rename", summary: "Give a mouse a name, as the pencil in Settings › Battery does. The name syncs to your other Macs. An empty --name goes back to the model name.",
                     params: [mouseParam, .init(name: "name", required: true, help: "the new name (\"\" goes back to the model name)")],
                     example: "m3 mice rename logi:unit-a1b2 --name \"Desk mouse\" --json") { args in
            let model = batteryModel
            let mouse = try findMouse(args)
            let name = try args.required("name", allowEmpty: true)
            let before = mouse.label
            model.rename(mouse, to: name)
            model.refresh()
            let after = model.mice.first { $0.id == mouse.id } ?? mouse
            var result = mouseSummary(after)
            result["changed"] = after.label != before
            return result
        },
        AgentCommand(name: "mice reset", summary: "Forget a mouse's charge history on every Mac, as Reset Charge History in Settings › Battery does. Without --yes it only shows what it would forget.",
                     params: [mouseParam],
                     example: "m3 mice reset logi:unit-a1b2 --yes --json", destructive: true) { args in
            let mouse = try findMouse(args)
            guard args.confirmed else {
                return ["wouldReset": mouseSummary(mouse),
                        "hint": "add --yes to forget its \(mouse.history.charges.count) charge(s) on every Mac. It can't be undone"]
            }
            batteryModel.resetHistory(for: mouse.id)
            return ["reset": mouse.id, "name": mouse.label]
        },

        // MARK: Changes

        AgentCommand(name: "counters reset", summary: "Set a counter on this Mac back to zero, as the Reset buttons in Settings › General do: mileage (with its charts and per-app distance), scroll, keystrokes, clicks, or all. Other Macs keep theirs. Without --yes it only shows what it would reset.",
                     params: [.init(name: "counter", required: true, positional: true, help: "mileage, scroll, keystrokes, clicks or all")],
                     example: "m3 counters reset clicks --yes --json", destructive: true) { args in
            let counter = try args.required("counter").lowercased()
            let metrics = MetricsStore.shared
            let current: JSONObject
            let reset: () -> Void
            switch counter {
            case "mileage": current = ["distance": MetricsStore.distanceText(forPoints: metrics.totalPoints, fine: true)]; reset = metrics.resetMileage
            case "scroll": current = ["scrolled": MetricsStore.distanceText(forPoints: metrics.scrollPoints, fine: true)]; reset = metrics.resetScroll
            case "keystrokes": current = ["keystrokes": metrics.keystrokes]; reset = metrics.resetKeystrokes
            case "clicks": current = ["leftClicks": metrics.leftClicks, "rightClicks": metrics.rightClicks]; reset = metrics.resetClicks
            case "all":
                current = ["distance": MetricsStore.distanceText(forPoints: metrics.totalPoints, fine: true),
                           "scrolled": MetricsStore.distanceText(forPoints: metrics.scrollPoints, fine: true),
                           "keystrokes": metrics.keystrokes, "leftClicks": metrics.leftClicks, "rightClicks": metrics.rightClicks]
                reset = metrics.resetAll
            default: throw AgentError.usage("<counter> must be mileage, scroll, keystrokes, clicks or all, not \"\(counter)\"")
            }
            guard args.confirmed else {
                return ["wouldReset": counter, "current": current,
                        "hint": "add --yes to set it to zero on this Mac. It can't be undone"]
            }
            reset()
            return ["reset": counter, "was": current]
        },
        AgentCommand(name: "menubar set", summary: "Choose what the menu bar shows, as Settings › General does: this Mac's distance or All Macs', and whether an All Macs total is marked with Σ. Only the options you give change; with none it shows the current choice.",
                     params: [.init(name: "shows", help: "this-mac or all-macs"),
                              .init(name: "marker", kind: .boolean, help: "true or false: put Σ before an All Macs total")],
                     example: "m3 menubar set --shows all-macs --json") { args in
            let before = (MenuBarSettings.showsAllMacs, MenuBarSettings.marksAllMacs)
            if let shows = args.string("shows") {
                switch shows.lowercased() {
                case "this-mac": if MenuBarSettings.showsAllMacs { MenuBarSettings.showsAllMacs = false }
                case "all-macs": if !MenuBarSettings.showsAllMacs { MenuBarSettings.showsAllMacs = true }
                default: throw AgentError.usage("--shows must be this-mac or all-macs, not \"\(shows)\"")
                }
            }
            if let marker = try args.bool("marker"), marker != MenuBarSettings.marksAllMacs { MenuBarSettings.marksAllMacs = marker }
            var result: JSONObject = ["shows": MenuBarSettings.showsAllMacs ? "all-macs" : "this-mac", "marker": MenuBarSettings.marksAllMacs,
                                      "menuBarTitle": menuBarTitle,
                                      "changed": before != (MenuBarSettings.showsAllMacs, MenuBarSettings.marksAllMacs)]
            if MenuBarSettings.showsAllMacs, !CloudSync.shared.isAvailable {
                result["note"] = "iCloud Drive is off, so the menu bar shows this Mac until it's back"
            }
            return result
        },

        // MARK: Windows

        AgentCommand(name: "charts open", summary: "Open a chart in its own window, as clicking it in the menu (or an m3tracker:// link) does.",
                     params: [.init(name: "chart", positional: true, help: "today (default), by-day or year")],
                     example: "m3 charts open by-day --json") { args in
            let chart = try chartCard(args.string("chart") ?? "today")
            try appDelegate().showChart(chart)
            return ["opened": chart.title]
        },
        AgentCommand(name: "settings open", summary: "Open the Settings window, as m3tracker://settings does.",
                     example: "m3 settings open --json") { _ in
            let delegate = try appDelegate()
            delegate.openPreferences()
            return ["opened": "Settings"]
        },
    ]

    // MARK: Shared parts

    static let mouseParam = AgentCommand.Param(name: "mouse", required: true, positional: true,
                                               help: "the mouse's id from `m3 mice list` (any unique start), or its name")

    /// The menu's view models, made once: commands read the same numbers the menu shows.
    private static let historyModel = HistoryViewModel()
    private static let batteryModel = BatteryViewModel()

    private static var menuBarTitle: String {
        MenuBarSettings.title(showsAllMacs: MenuBarSettings.showsAllMacs, marksAllMacs: MenuBarSettings.marksAllMacs,
                              isSyncAvailable: CloudSync.shared.isAvailable,
                              thisMacPoints: MetricsStore.shared.totalPoints, allMacsPoints: CloudSync.shared.allMacsPoints)
    }

    private static func miles(_ points: Double) -> Double { points / 72.0 / 12.0 / 5280.0 }

    /// Miles to the thousandth, the menu's finest step.
    private static func round(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    private static let hourFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The bucket's start on this Mac's clock, as the chart labels it.
    private static func localTime(_ date: Date, hourly: Bool) -> String {
        (hourly ? hourFormat : dayFormat).string(from: date)
    }

    /// The same names as the m3tracker:// links.
    private static func chartCard(_ name: String) throws -> MenuCard {
        switch name.lowercased() {
        case "today": return .todayByHour
        case "by-day", "week": return .byDay
        case "year": return .yearToDate
        default: throw AgentError.usage("the chart must be today, by-day or year, not \"\(name)\"")
        }
    }

    private static func appRange(_ name: String) throws -> AppUsageRange {
        switch name.lowercased() {
        case "today": return .today
        case "7days", "7-days", "week": return .sevenDays
        case "all", "all-time": return .allTime
        default: throw AgentError.usage("--range must be today, 7days or all, not \"\(name)\"")
        }
    }

    private static func appDelegate() throws -> AppDelegate {
        guard let delegate = NSApp.delegate as? AppDelegate, delegate.showsWindows else {
            throw AgentError.invalid("a test copy (APP_STORE) opens no windows. Run this against the installed M3 Tracker")
        }
        return delegate
    }

    private static func findMouse(_ args: Args) throws -> BatteryViewModel.Mouse {
        let wanted = try args.required("mouse")
        let model = batteryModel
        model.refresh()
        if let exact = model.mice.first(where: { $0.id == wanted }) { return exact }
        let named = model.mice.filter { $0.label.localizedCaseInsensitiveCompare(wanted) == .orderedSame }
        if named.count == 1 { return named[0] }
        let matches = model.mice.filter { $0.id.hasPrefix(wanted) }
        if matches.count > 1 || named.count > 1 {
            throw AgentError.usage("\"\(wanted)\" matches more than one mouse. Use more of its id from `m3 mice list`")
        }
        guard let mouse = matches.first else { throw AgentError.notFound("no mouse \"\(wanted)\". Run `m3 mice list`") }
        return mouse
    }

    private static func mouseSummary(_ mouse: BatteryViewModel.Mouse) -> JSONObject {
        var summary: JSONObject = ["id": mouse.id, "name": mouse.label, "model": mouse.name,
                                   "connected": mouse.connected != nil, "charging": mouse.isCharging,
                                   "charges": mouse.history.charges.count]
        if let percent = mouse.percent { summary["percent"] = percent }
        if let current = mouse.history.current {
            summary["currentChargeMiles"] = round(current.miles)
            summary["currentChargeUsedPercent"] = current.usedPercent
        }
        if let average = mouse.history.averageMilesPerFullCharge { summary["milesPerFullCharge"] = round(average) }
        return summary
    }

    /// One page of a list, with `total` and, when more remain, `nextOffset`.
    private static func page<T>(_ items: [T], key: String, _ args: Args, _ map: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50), offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be above 0 and --offset 0 or more") }
        let slice = items.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(map), "total": items.count]
        if offset + slice.count < items.count { result["nextOffset"] = offset + slice.count }
        return result
    }
}

extension Args {
    /// Like `required`, but "" is a value (it clears a name).
    func required(_ name: String, allowEmpty: Bool) throws -> String {
        guard let value = values[name] else { throw AgentError.usage("missing --\(name)") }
        return value
    }
}
