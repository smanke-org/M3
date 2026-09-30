import Foundation

/// Tracks mileage in time buckets so it can be charted, independent of the
/// all-time running total kept by `MetricsStore`. Persists to `UserDefaults`
/// so history survives restarts, same as the totals.
final class MileageHistoryStore {
    /// Pointer mileage.
    static let shared = MileageHistoryStore(keyPrefix: "history")
    /// Distance scrolled, charted as a second line. Same buckets, rules and
    /// retention, stored under its own keys.
    static let scroll = MileageHistoryStore(keyPrefix: "scrollHistory")

    struct Bucket: Codable, Identifiable, Equatable {
        var start: Date
        var points: Double
        var id: Date { start }
    }

    private let defaults = UserDefaults.standard
    private struct Keys {
        let hourly: String
        let daily: String
    }
    private let keys: Keys

    // Keep a bit more than we need so nothing is lost right at a boundary.
    private let hourlyRetention: TimeInterval = 26 * 3600
    private let dailyRetention: TimeInterval = 370 * 86400

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }()

    private var hourly: [Bucket]
    private var daily: [Bucket]
    private var dirty = false
    private var saveTimer: Timer?

    private let pointsPerInch: Double = 72.0
    private let inchesPerFoot: Double = 12.0
    private let feetPerMile: Double = 5280.0

    private init(keyPrefix: String) {
        keys = Keys(hourly: "\(keyPrefix).hourly", daily: "\(keyPrefix).daily")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = defaults.data(forKey: keys.hourly), let decoded = try? decoder.decode([Bucket].self, from: data) {
            hourly = decoded
        } else {
            hourly = []
        }
        if let data = defaults.data(forKey: keys.daily), let decoded = try? decoder.decode([Bucket].self, from: data) {
            daily = decoded
        } else {
            daily = []
        }

        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveIfNeeded()
        }
    }

    func recordMovement(points: Double, at date: Date = Date()) {
        guard points > 0, points.isFinite else { return }

        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        if var last = hourly.last, last.start == hourStart {
            last.points += points
            hourly[hourly.count - 1] = last
        } else {
            hourly.append(Bucket(start: hourStart, points: points))
        }

        let dayStart = calendar.startOfDay(for: date)
        if var last = daily.last, last.start == dayStart {
            last.points += points
            daily[daily.count - 1] = last
        } else {
            daily.append(Bucket(start: dayStart, points: points))
        }

        prune(now: date)
        dirty = true
    }

    private func prune(now: Date) {
        let hourlyCutoff = now.addingTimeInterval(-hourlyRetention)
        let dailyCutoff = now.addingTimeInterval(-dailyRetention)
        hourly.removeAll { $0.start < hourlyCutoff }
        daily.removeAll { $0.start < dailyCutoff }
    }

    /// Earliest day with recorded movement, used to backfill a tracking start
    /// date for installs that predate it being recorded.
    var earliestRecordedDay: Date? {
        daily.map(\.start).min()
    }

    /// This Mac's raw buckets (points, not miles), for publishing to the other Macs.
    var hourlyBuckets: [Bucket] { hourly }
    var dailyBuckets: [Bucket] { daily }

    /// Combines bucket sets from several Macs into one series on *this* Mac's calendar.
    ///
    /// Another Mac may be in a different time zone, so its day (and, for half-hour
    /// offsets, hour) boundaries don't line up with ours: summing on the raw `start`
    /// would split one day into two. Each bucket is instead re-keyed to the local
    /// hour or day containing its midpoint — the local period it overlaps most.
    static func merge(_ sets: [[Bucket]], unit: Calendar.Component, calendar: Calendar) -> [Bucket] {
        var byStart: [Date: Double] = [:]
        for set in sets {
            for bucket in set {
                let key = localPeriodStart(for: bucket.start, unit: unit, calendar: calendar)
                byStart[key, default: 0] += bucket.points
            }
        }
        return byStart
            .map { Bucket(start: $0.key, points: $0.value) }
            .sorted { $0.start < $1.start }
    }

    /// The local hour or day that a period starting at `start` (on any Mac's
    /// calendar) overlaps most — the one containing its midpoint. Shared with the
    /// per-app totals so both follow the same time-zone rule.
    static func localPeriodStart(for start: Date, unit: Calendar.Component, calendar: Calendar) -> Date {
        let halfSpan: TimeInterval = unit == .hour ? 30 * 60 : 12 * 3600
        let midpoint = start.addingTimeInterval(halfSpan)
        return unit == .hour
            ? (calendar.dateInterval(of: .hour, for: midpoint)?.start ?? start)
            : calendar.startOfDay(for: midpoint)
    }

    /// `merge` on this store's own calendar.
    func merge(_ sets: [[Bucket]], unit: Calendar.Component) -> [Bucket] {
        Self.merge(sets, unit: unit, calendar: calendar)
    }

    func resetHistory() {
        hourly = []
        daily = []
        dirty = true
        saveIfNeeded()
    }

    // MARK: - Queries (values returned in miles)

    func last24Hours(now: Date = Date()) -> [Bucket] {
        let cutoff = calendar.date(byAdding: .hour, value: -23, to: calendar.dateInterval(of: .hour, for: now)?.start ?? now) ?? now
        var buckets = hourly.filter { $0.start >= cutoff }
        buckets = fillGaps(buckets, unit: .hour, from: cutoff, to: now)
        return buckets.map(toMiles)
    }

    /// Today's mileage broken out by hour-of-day (00:00–23:00), rather than a rolling
    /// 24-hour window. Hours after "now" are included as zero so the chart's x-axis
    /// spans the full day with a "now" marker partway through.
    ///
    /// `source` defaults to this Mac's buckets; pass a merged set to chart all Macs.
    func todayByHour(from source: [Bucket]? = nil, now: Date = Date()) -> [Bucket] {
        let dayStart = calendar.startOfDay(for: now)
        var byStart: [Date: Double] = [:]
        for bucket in (source ?? hourly) where bucket.start >= dayStart {
            byStart[bucket.start, default: 0] += bucket.points
        }

        var result: [Bucket] = []
        for hourOffset in 0..<24 {
            guard let hourStart = calendar.date(byAdding: .hour, value: hourOffset, to: dayStart) else { continue }
            result.append(Bucket(start: hourStart, points: byStart[hourStart] ?? 0))
        }
        return result.map(toMiles)
    }

    func last7Days(from source: [Bucket]? = nil, now: Date = Date()) -> [Bucket] {
        let cutoff = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        var buckets = (source ?? daily).filter { $0.start >= cutoff }
        buckets = fillGaps(buckets, unit: .day, from: cutoff, to: now)
        return buckets.map(toMiles)
    }

    func yearToDate(from source: [Bucket]? = nil, now: Date = Date()) -> [Bucket] {
        let components = calendar.dateComponents([.year], from: now)
        let jan1 = calendar.date(from: DateComponents(year: components.year, month: 1, day: 1)) ?? now
        var buckets = (source ?? daily).filter { $0.start >= jan1 }
        buckets = fillGaps(buckets, unit: .day, from: jan1, to: now)
        return buckets.map(toMiles)
    }

    private func toMiles(_ bucket: Bucket) -> Bucket {
        Bucket(start: bucket.start, points: (bucket.points / pointsPerInch / inchesPerFoot / feetPerMile))
    }

    /// Fills in zero-value buckets for hours/days with no recorded movement so charts show continuous axes.
    private func fillGaps(_ buckets: [Bucket], unit: Calendar.Component, from: Date, to: Date) -> [Bucket] {
        var byStart: [Date: Double] = [:]
        for b in buckets { byStart[b.start, default: 0] += b.points }

        var result: [Bucket] = []
        var cursor = unit == .hour ? (calendar.dateInterval(of: .hour, for: from)?.start ?? from) : calendar.startOfDay(for: from)
        let end = unit == .hour ? (calendar.dateInterval(of: .hour, for: to)?.start ?? to) : calendar.startOfDay(for: to)

        while cursor <= end {
            result.append(Bucket(start: cursor, points: byStart[cursor] ?? 0))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    // MARK: - Persistence

    func saveIfNeeded() {
        guard dirty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(hourly) {
            defaults.set(data, forKey: keys.hourly)
        }
        if let data = try? encoder.encode(daily) {
            defaults.set(data, forKey: keys.daily)
        }
        dirty = false
    }
}
