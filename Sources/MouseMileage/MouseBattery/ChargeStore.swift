import Foundation

/// A battery reading, kept only when it differs from the one before.
struct BatterySample: Codable, Equatable {
    var date: Date
    var percent: Int
    var isCharging: Bool
}

/// One mouse's raw record on one Mac: movement while it was the mouse in use,
/// and its battery readings. Charges are derived from these, not stored, so
/// several Macs' records for the same mouse combine by simple union.
struct MouseLog: Codable, Equatable {
    /// "logi:<serial>" or "apple:<serial>": the same on every Mac, and on
    /// every Easy-Switch channel.
    var key: String
    var name: String
    var movement: [MileageHistoryStore.Bucket] = []
    var samples: [BatterySample] = []
    /// Set by Reset Charge History, and synced, so data held by other Macs
    /// from before the reset doesn't bring the old charges back.
    var resetAt: Date? = nil
}

/// Travel on one battery charge.
struct Charge: Equatable, Identifiable {
    var start: Date
    /// Nil for the charge the mouse is on now.
    var end: Date?
    /// The level once it stopped charging (the highest reading before use began).
    var startPercent: Int
    var lowestPercent: Int
    var points: Double

    var id: Date { start }
    var isCurrent: Bool { end == nil }
    var usedPercent: Int { max(startPercent - lowestPercent, 0) }
    var miles: Double { points / 72.0 / 12.0 / 5280.0 }

    /// Below this much battery used, extrapolating to a full charge is noise.
    static let minimumUsedPercent = 10

    /// Miles ÷ battery used × 100: comparable across charges however low the
    /// battery was allowed to run before recharging.
    var milesPerFullCharge: Double? {
        guard usedPercent >= Self.minimumUsedPercent else { return nil }
        return miles / Double(usedPercent) * 100
    }
}

/// One mouse's history combined from every Mac.
struct MouseChargeHistory: Equatable, Identifiable {
    var key: String
    var name: String
    var charges: [Charge]
    var latest: BatterySample?

    var id: String { key }
    var current: Charge? { charges.last.flatMap { $0.isCurrent ? $0 : nil } }
    var completed: [Charge] { charges.filter { !$0.isCurrent } }

    /// Average over completed charges that used enough battery to count.
    var averageMilesPerFullCharge: Double? {
        let values = completed.compactMap(\.milesPerFullCharge)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Records movement and battery readings per mouse, for mileage per charge.
/// Separate from the main mileage and from per-app usage: its reset touches
/// nothing else, and nothing else resets it.
final class ChargeStore {
    static let shared = ChargeStore()
    static let didUpdateNotification = Notification.Name("ChargeStore.didUpdate")

    private(set) var logs: [String: MouseLog]

    private var dirty = false
    private var saveTimer: Timer?
    private let retention: TimeInterval = 400 * 86400
    private static let defaultsKey = "charges.v1"

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
        logs = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? Self.decoder.decode([String: MouseLog].self, from: $0) } ?? [:]
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveIfNeeded()
        }
    }

    // MARK: - Recording (main thread)

    /// Hot path: runs on every mouse move while a tracked mouse is moving.
    func record(points: Double, mouse key: String, at date: Date = Date()) {
        guard logs[key] != nil else { return }
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        if logs[key]!.movement.last?.start == hourStart {
            logs[key]!.movement[logs[key]!.movement.count - 1].points += points
        } else {
            logs[key]!.movement.append(MileageHistoryStore.Bucket(start: hourStart, points: points))
            prune(key, now: date)
        }
        dirty = true
    }

    func recordBattery(mouse key: String, name: String, percent: Int, isCharging: Bool, at date: Date = Date()) {
        var log = logs[key] ?? MouseLog(key: key, name: name)
        log.name = name
        let last = log.samples.last
        if last?.percent != percent || last?.isCharging != isCharging {
            log.samples.append(BatterySample(date: date, percent: percent, isCharging: isCharging))
        }
        guard log != logs[key] else { return }
        logs[key] = log
        dirty = true
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    /// Forgets this mouse's charges on every Mac.
    func resetHistory(mouse key: String, at date: Date = Date()) {
        guard var log = logs[key] else { return }
        log.movement = []
        log.samples = log.samples.last.map { [BatterySample(date: date, percent: $0.percent, isCharging: $0.isCharging)] } ?? []
        log.resetAt = date
        logs[key] = log
        dirty = true
        saveIfNeeded()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    private func prune(_ key: String, now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        logs[key]?.movement.removeAll { $0.start < cutoff }
        logs[key]?.samples.removeAll { $0.date < cutoff }
    }

    func saveIfNeeded() {
        guard dirty else { return }
        if let data = try? Self.encoder.encode(logs) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        dirty = false
    }

    // MARK: - Charges (pure)

    /// Combines each mouse's logs from every Mac (this Mac's first, so its
    /// name for the mouse wins) into its charge history.
    static func histories(from logs: [MouseLog]) -> [MouseChargeHistory] {
        let byKey = Dictionary(grouping: logs, by: \.key)
        return byKey.values.compactMap { group -> MouseChargeHistory? in
            guard let first = group.first else { return nil }
            let resetAt = group.compactMap(\.resetAt).max() ?? .distantPast
            let samples = group.flatMap(\.samples).filter { $0.date >= resetAt }.sorted { $0.date < $1.date }
            let movement = group.flatMap(\.movement).filter { $0.start.addingTimeInterval(3600) > resetAt }
            return MouseChargeHistory(key: first.key, name: first.name,
                                      charges: charges(samples: samples, movement: movement),
                                      latest: samples.last)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Splits battery readings into charges, and adds up the movement in each.
    ///
    /// - A charge ends at the first reading that is charging, or that rose
    ///   ≥10 points above the lowest level since the charge was last used.
    ///   The rise catches a recharge the app never saw happen (the Mac asleep,
    ///   or a Magic Mouse charged while disconnected); the margin ignores the
    ///   point or two that battery estimates wander by.
    /// - The next charge begins at the first reading that isn't charging.
    ///   While the level is still rising (readings from a charge in progress)
    ///   the starting level follows it up.
    /// - Movement is in hourly buckets. A bucket straddling a boundary goes
    ///   to the newer charge, so a new charge's first miles show straight away.
    static func charges(samples: [BatterySample], movement: [MileageHistoryStore.Bucket]) -> [Charge] {
        var result: [Charge] = []
        var current: Charge?

        func begin(_ sample: BatterySample) {
            current = Charge(start: sample.date, end: nil, startPercent: sample.percent,
                             lowestPercent: sample.percent, points: 0)
        }

        for sample in samples {
            guard var charge = current else {
                if !sample.isCharging { begin(sample) }
                continue
            }
            let hasBeenUsed = charge.lowestPercent < charge.startPercent
            if sample.isCharging || (hasBeenUsed && sample.percent >= charge.lowestPercent + 10) {
                charge.end = sample.date
                result.append(charge)
                current = nil
                if !sample.isCharging { begin(sample) }
            } else if !hasBeenUsed && sample.percent > charge.startPercent {
                charge.startPercent = sample.percent
                charge.lowestPercent = sample.percent
                current = charge
            } else {
                charge.lowestPercent = min(charge.lowestPercent, sample.percent)
                current = charge
            }
        }
        if let current { result.append(current) }

        for bucket in movement {
            let bucketEnd = bucket.start.addingTimeInterval(3600)
            guard let index = result.lastIndex(where: { $0.start < bucketEnd }) else { continue }
            if let end = result[index].end, bucket.start >= end { continue }
            result[index].points += bucket.points
        }
        return result
    }
}
