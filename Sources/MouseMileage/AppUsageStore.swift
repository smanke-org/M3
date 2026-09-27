import AppKit

/// Mileage, clicks, and keystrokes credited to one app.
struct AppUsage: Codable, Equatable {
    var points: Double = 0
    var clicks: Int = 0
    var keystrokes: Int = 0

    mutating func add(_ other: AppUsage) {
        points += other.points
        clicks += other.clicks
        keystrokes += other.keystrokes
    }
}

/// Per-app usage for one local calendar day.
///
/// An array of these rather than a `[Date: ...]` dictionary: Codable encodes
/// non-string-keyed dictionaries as flat key/value arrays.
struct AppDay: Codable, Equatable {
    var start: Date
    var apps: [String: AppUsage]
}

/// One Mac's per-app data — this Mac's, or one synced from another Mac.
struct AppUsageSnapshot: Equatable {
    var allTime: [String: AppUsage]
    var days: [AppDay]
    var names: [String: String]
}

enum AppUsageRange: String, CaseIterable, Identifiable {
    case today, sevenDays, allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .allTime: return "All"
        }
    }
}

/// Apps ranked by mileage for one range.
struct AppRanking: Equatable {
    struct Row: Identifiable, Equatable {
        let id: String      // bundle ID
        let name: String
        let usage: AppUsage
    }

    var rows: [Row]

    static let empty = AppRanking(rows: [])
}

/// Credits mileage, clicks, and keystrokes to whichever app has focus.
///
/// The focused app is cached from activation notifications rather than looked up
/// per event: `MetricsStore.addMovement` runs on every mouse move, so crediting
/// has to be a dictionary add and nothing more.
final class AppUsageStore {
    static let shared = AppUsageStore()

    /// Used when no app has focus (e.g. the login window) or it has no identity.
    static let unknownKey = "unknown"

    private(set) var allTime: [String: AppUsage]
    private(set) var days: [AppDay]
    private(set) var names: [String: String]

    private var currentKey = AppUsageStore.unknownKey
    private var dirty = false
    private var saveTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// Enough for a 7-day window plus the day that's rolling off.
    private let dayRetention = 8

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let allTime = "apps.allTime"
        static let days = "apps.days"
        static let names = "apps.names"
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            UserDefaults.standard.data(forKey: key).flatMap { try? Self.decoder.decode(T.self, from: $0) }
        }
        allTime = load(Keys.allTime, as: [String: AppUsage].self) ?? [:]
        days = load(Keys.days, as: [AppDay].self) ?? []
        names = load(Keys.names, as: [String: String].self) ?? [:]
        names[Self.unknownKey] = "Unknown app"

        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveIfNeeded()
        }
    }

    /// Starts following the focused app. Call before events start arriving.
    func start() {
        focus(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.focus(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func focus(_ app: NSRunningApplication?) {
        guard let app else {
            currentKey = Self.unknownKey
            return
        }
        let key = app.bundleIdentifier ?? app.localizedName ?? Self.unknownKey
        currentKey = key
        if let name = app.localizedName, names[key] != name {
            names[key] = name
            dirty = true
        }
    }

    // MARK: - Recording (main thread, hot path)

    func record(points: Double) {
        credit { $0.points += points }
    }

    func recordClick() {
        credit { $0.clicks += 1 }
    }

    func recordKeystroke() {
        credit { $0.keystrokes += 1 }
    }

    private func credit(_ change: (inout AppUsage) -> Void) {
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        if days.last?.start != dayStart {
            days.append(AppDay(start: dayStart, apps: [:]))
            prune(now: now)
        }
        change(&days[days.count - 1].apps[currentKey, default: AppUsage()])
        change(&allTime[currentKey, default: AppUsage()])
        dirty = true
    }

    private func prune(now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -(dayRetention - 1), to: calendar.startOfDay(for: now)) else { return }
        days.removeAll { $0.start < cutoff }
    }

    /// Clears the chosen metrics for every app, matching the Preferences resets.
    func reset(points: Bool, clicks: Bool, keystrokes: Bool) {
        // Apps with nothing left are dropped, so the lists don't fill with zeroes.
        func cleared(_ apps: [String: AppUsage]) -> [String: AppUsage] {
            apps.compactMapValues { usage in
                var usage = usage
                if points { usage.points = 0 }
                if clicks { usage.clicks = 0 }
                if keystrokes { usage.keystrokes = 0 }
                return usage == AppUsage() ? nil : usage
            }
        }
        allTime = cleared(allTime)
        days = days.map { AppDay(start: $0.start, apps: cleared($0.apps)) }
        dirty = true
        saveIfNeeded()
    }

    var snapshot: AppUsageSnapshot {
        AppUsageSnapshot(allTime: allTime, days: days, names: names)
    }

    // MARK: - Ranking (pure)

    /// Ranks apps by mileage across one or more Macs' data.
    ///
    /// `snapshots` puts this Mac first, so its app names win when Macs disagree.
    /// Other Macs' days are re-keyed onto this Mac's calendar with the same
    /// midpoint rule as the charts, so a Mac in another time zone lines up.
    static func ranking(range: AppUsageRange, snapshots: [AppUsageSnapshot],
                        calendar: Calendar, now: Date = Date()) -> AppRanking {
        var totals: [String: AppUsage] = [:]

        switch range {
        case .allTime:
            for snapshot in snapshots {
                for (key, usage) in snapshot.allTime { totals[key, default: AppUsage()].add(usage) }
            }
        case .today, .sevenDays:
            let today = calendar.startOfDay(for: now)
            let earliest = range == .today
                ? today
                : (calendar.date(byAdding: .day, value: -6, to: today) ?? today)
            for snapshot in snapshots {
                for day in snapshot.days {
                    let local = MileageHistoryStore.localPeriodStart(for: day.start, unit: .day, calendar: calendar)
                    guard local >= earliest, local <= today else { continue }
                    for (key, usage) in day.apps { totals[key, default: AppUsage()].add(usage) }
                }
            }
        }

        func name(for key: String) -> String {
            for snapshot in snapshots {
                if let name = snapshot.names[key] { return name }
            }
            return key
        }

        func ranksBefore(_ a: AppRanking.Row, _ b: AppRanking.Row) -> Bool {
            if a.usage.points != b.usage.points { return a.usage.points > b.usage.points }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        var rows: [AppRanking.Row] = []
        for (key, usage) in totals where usage != AppUsage() {
            rows.append(AppRanking.Row(id: key, name: name(for: key), usage: usage))
        }
        rows.sort(by: ranksBefore)
        return AppRanking(rows: rows)
    }

    /// This Mac's calendar, for ranking.
    var localCalendar: Calendar { calendar }

    // MARK: - Persistence

    func saveIfNeeded() {
        guard dirty else { return }
        if let data = try? Self.encoder.encode(allTime) { defaults.set(data, forKey: Keys.allTime) }
        if let data = try? Self.encoder.encode(days) { defaults.set(data, forKey: Keys.days) }
        if let data = try? Self.encoder.encode(names) { defaults.set(data, forKey: Keys.names) }
        dirty = false
    }
}

/// A column the Preferences Apps list can be sorted by.
enum AppSortColumn: String {
    case name, distance, clicks, keystrokes

    /// Ties fall back to the name, A–Z, so the order is stable either way round.
    static func sorted(_ rows: [AppRanking.Row], by column: AppSortColumn, ascending: Bool) -> [AppRanking.Row] {
        func compare(_ a: AppRanking.Row, _ b: AppRanking.Row) -> ComparisonResult {
            switch column {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name)
            case .distance: return value(a.usage.points, b.usage.points)
            case .clicks: return value(a.usage.clicks, b.usage.clicks)
            case .keystrokes: return value(a.usage.keystrokes, b.usage.keystrokes)
            }
        }
        return rows.sorted { a, b in
            let order = compare(a, b)
            if order == .orderedSame {
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func value<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
