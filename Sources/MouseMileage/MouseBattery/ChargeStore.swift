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
    /// "logi:unit-<unit ID>" or "apple:<serial>": the same on every Mac, and on
    /// every Easy-Switch channel.
    var key: String
    var name: String
    var movement: [MileageHistoryStore.Bucket] = []
    var samples: [BatterySample] = []
    /// Set by Reset Charge History, and synced, so data held by other Macs
    /// from before the reset doesn't bring the old charges back.
    var resetAt: Date? = nil

    // Added in 1.15.5; optional so earlier files decode.
    /// Earlier keys for this mouse. 1.15.0–1.15.4 keyed a Logitech mouse by
    /// its serial number when that read succeeded, so a failed read split one
    /// mouse into two. Logs under these keys belong to this mouse.
    var aliases: [String]? = nil
    var serial: String? = nil
    /// The user's name for the mouse. The most recently set one wins across Macs.
    var nickname: String? = nil
    var nicknameUpdatedAt: Date? = nil
}

/// Model names as the mice report them, trimmed to what's worth showing.
enum MouseName {
    /// "MX Master 4 M" → "MX Master 4" (the " M" marks the Mac edition), and
    /// "Wireless Mouse MX Master 2S" → "MX Master 2S".
    static func model(_ product: String) -> String {
        var name = product.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("Wireless Mouse "), name.count > "Wireless Mouse ".count {
            name = String(name.dropFirst("Wireless Mouse ".count))
        }
        if name.hasSuffix(" M") { name = String(name.dropLast(2)) }
        return name
    }

    /// A short ID to tell identical models apart: the end of the serial
    /// number (printed on the mouse's label), or of its other identifier.
    static func idSuffix(key: String, serial: String?) -> String {
        let source = serial ?? key.split(separator: ":").last.map { String($0.split(separator: "-").last ?? $0) } ?? key
        return String(source.suffix(4)).uppercased()
    }
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
    /// The model name.
    var name: String
    var charges: [Charge]
    var latest: BatterySample?
    var serial: String? = nil
    var nickname: String? = nil

    var idSuffix: String { MouseName.idSuffix(key: key, serial: serial) }

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

    /// Records who this mouse is, and folds in any log kept under an earlier
    /// key for it (see `MouseLog.aliases`), so its history is one again.
    func identify(mouse key: String, name: String, serial: String?, aliases: [String]) {
        var log = logs[key] ?? MouseLog(key: key, name: name)
        let before = log
        log.name = name
        if let serial { log.serial = serial }
        for alias in aliases where alias != key {
            if let old = logs.removeValue(forKey: alias) {
                log = Self.merged(old, into: log)
            }
            if !(log.aliases ?? []).contains(alias) {
                log.aliases = (log.aliases ?? []) + [alias]
            }
        }
        guard log != before || logs[key] == nil else { return }
        logs[key] = log
        dirty = true
        saveIfNeeded()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    /// Names a mouse, or with nil/empty goes back to its model name. Works
    /// for a mouse that isn't connected to this Mac too: its log here then
    /// carries only the name, which syncs to the others.
    func rename(mouse key: String, model: String, to nickname: String?, at date: Date = Date()) {
        var log = logs[key] ?? MouseLog(key: key, name: model)
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        log.nickname = (trimmed?.isEmpty ?? true) ? nil : trimmed
        log.nicknameUpdatedAt = date
        logs[key] = log
        dirty = true
        saveIfNeeded()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    /// One mouse's two logs as one: movement summed by hour, readings merged
    /// in time order, the later reset and the newer nickname kept.
    static func merged(_ other: MouseLog, into log: MouseLog) -> MouseLog {
        var result = log
        var byHour: [Date: Double] = [:]
        for bucket in log.movement + other.movement { byHour[bucket.start, default: 0] += bucket.points }
        result.movement = byHour.map { MileageHistoryStore.Bucket(start: $0.key, points: $0.value) }.sorted { $0.start < $1.start }

        var samples: [BatterySample] = []
        for sample in (log.samples + other.samples).sorted(by: { $0.date < $1.date }) {
            // Kept only when it differs from the reading before, as when recorded.
            if let last = samples.last, last.percent == sample.percent, last.isCharging == sample.isCharging { continue }
            samples.append(sample)
        }
        result.samples = samples

        result.resetAt = [log.resetAt, other.resetAt].compactMap { $0 }.max()
        result.serial = log.serial ?? other.serial
        if (other.nicknameUpdatedAt ?? .distantPast) > (log.nicknameUpdatedAt ?? .distantPast) {
            result.nickname = other.nickname
            result.nicknameUpdatedAt = other.nicknameUpdatedAt
        }
        let aliases = Set((log.aliases ?? []) + (other.aliases ?? []) + [other.key]).subtracting([log.key])
        result.aliases = aliases.isEmpty ? nil : aliases.sorted()
        return result
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
    ///
    /// Logs are grouped by key and by `aliases`, so a Mac still on 1.15.4,
    /// publishing a Logitech mouse under its serial-number key, lands in the
    /// same history as soon as any Mac has recorded that alias.
    static func histories(from logs: [MouseLog]) -> [MouseChargeHistory] {
        // Union-find over keys, joined by aliases.
        var parent: [String: String] = [:]
        func root(_ key: String) -> String {
            var key = key
            while let next = parent[key], next != key { key = next }
            return key
        }
        func join(_ a: String, _ b: String) {
            let (ra, rb) = (root(a), root(b))
            if ra != rb { parent[rb] = ra }
        }
        for log in logs {
            parent[log.key] = parent[log.key] ?? log.key
            for alias in log.aliases ?? [] {
                parent[alias] = parent[alias] ?? alias
                join(log.key, alias)
            }
        }

        var groups: [String: [MouseLog]] = [:]
        var order: [String] = []
        for log in logs {
            let group = root(log.key)
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(log)
        }

        return order.compactMap { id -> MouseChargeHistory? in
            guard let group = groups[id], let first = group.first else { return nil }
            // The current key is the one that lists the others as aliases.
            let key = group.first { !($0.aliases ?? []).isEmpty }?.key ?? first.key
            let resetAt = group.compactMap(\.resetAt).max() ?? .distantPast
            let samples = group.flatMap(\.samples).filter { $0.date >= resetAt }.sorted { $0.date < $1.date }
            let movement = group.flatMap(\.movement).filter { $0.start.addingTimeInterval(3600) > resetAt }
            let named = group.filter { $0.nicknameUpdatedAt != nil }.max { $0.nicknameUpdatedAt! < $1.nicknameUpdatedAt! }
            return MouseChargeHistory(key: key, name: MouseName.model(first.name),
                                      charges: charges(samples: samples, movement: movement),
                                      latest: samples.last,
                                      serial: group.lazy.compactMap(\.serial).first,
                                      nickname: named?.nickname)
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
