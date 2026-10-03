import AppKit
import CryptoKit
import IOKit
import SystemConfiguration

/// A stable identity for this Mac that is safe to write into iCloud Drive.
enum DeviceIdentity {
    /// Derived from the hardware UUID, so it is stable across reinstalls and is
    /// *not* carried to a new Mac by Migration Assistant — a UUID generated and
    /// kept in UserDefaults would be, and two Macs would then share one file.
    /// Hashed so the raw hardware identifier never leaves the machine.
    static let deviceID: String = {
        let source = hardwareUUID() ?? fallbackUUID()
        let digest = SHA256.hash(data: Data("\(source):\(AppInfo.bundleIdentifier)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }()

    /// The name set in System Settings › General › About. Deliberately not
    /// `Host.current().localizedName`, which can block for seconds on DNS.
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Only reached if IOKit won't give up the hardware UUID.
    private static func fallbackUUID() -> String {
        let key = "sync.fallbackDeviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}

/// One Mac's contribution, as written to iCloud Drive. Totals are cumulative, so
/// a stale, repeated, or delayed file can never cause double counting.
struct DeviceRecord: Codable, Equatable {
    var schema: Int = 1
    var deviceID: String
    var deviceName: String
    var updatedAt: Date
    var trackingStartedAt: Date
    var totalPoints: Double
    var keystrokes: Int
    var leftClicks: Int
    var rightClicks: Int
    var hourly: [MileageHistoryStore.Bucket]
    var daily: [MileageHistoryStore.Bucket]

    // Per-app usage, added in 1.14.2. Optional so files written by 1.14.0–1.14.1
    // still decode; those versions ignore these keys when reading newer files.
    var apps: [String: AppUsage]? = nil
    var appDays: [AppDay]? = nil
    var appNames: [String: String]? = nil

    // Mileage per battery charge, added in 1.15.0. Optional for the same reason.
    var mice: [MouseLog]? = nil

    // Distance scrolled, added in 1.15.9. Optional for the same reason.
    var scrollPoints: Double? = nil
    var scrollHourly: [MileageHistoryStore.Bucket]? = nil
    var scrollDaily: [MileageHistoryStore.Bucket]? = nil

    /// Version, permissions and input counts, for looking into a problem on
    /// this Mac from another one. Added in 1.15.12; optional like the rest.
    var diagnostics: DeviceDiagnostics? = nil

    /// This Mac's per-app data in the form the ranking takes.
    var appSnapshot: AppUsageSnapshot {
        AppUsageSnapshot(allTime: apps ?? [:], days: appDays ?? [], names: appNames ?? [:])
    }

    /// Everything except the timestamp, to tell whether anything actually changed.
    var content: DeviceRecord {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }
}

/// Shares mileage between the user's Macs through a folder in iCloud Drive.
///
/// Each Mac writes only its own file, `M3 Tracker/Devices/<deviceID>.json`, and
/// reads everyone else's. With a single writer per file there are no sync conflicts
/// to resolve. The app is unsandboxed, so this is ordinary file I/O — no iCloud
/// entitlement or provisioning profile is involved.
///
/// All file access runs on a background queue: `EventMonitor` drives the stores
/// from the main thread on every mouse move, and a coordinated read can wait on
/// the iCloud daemon. State the UI reads is only mutated on the main thread.
final class CloudSync {
    static let shared = CloudSync()
    static let didUpdateNotification = Notification.Name("CloudSync.didUpdate")

    /// Other Macs' latest records, keyed by device ID. Main thread only.
    private(set) var remoteRecords: [String: DeviceRecord] = [:]
    /// Whether iCloud Drive is on and the sync folder can be used. Main thread only.
    private(set) var isAvailable = false

    private let queue = DispatchQueue(label: "com.smanke.MouseMileage.cloudsync", qos: .utility)
    private var timer: Timer?
    private var lastPublished: DeviceRecord?
    private let syncInterval: TimeInterval = 60

    private enum Keys {
        static let remoteCache = "sync.remoteRecords"
        static let allMacsMiles = "diagnostics.allMacsMiles"
        static let macCount = "diagnostics.syncMacCount"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        // Last-known totals from the other Macs, so All Macs is right at launch
        // instead of briefly showing only this Mac until the first read lands.
        if let data = UserDefaults.standard.data(forKey: Keys.remoteCache),
           let cached = try? Self.decoder.decode([String: DeviceRecord].self, from: data) {
            remoteRecords = cached
        }
        isAvailable = Self.syncFolder() != nil
    }

    // MARK: - Location

    /// `iCloud Drive/M3 Tracker/Devices`, or nil when iCloud Drive is off.
    /// `M3_SYNC_FOLDER` redirects it, so a debug build — which shares this Mac's
    /// device ID — can be tested without overwriting the installed app's file.
    static func syncFolder() -> URL? {
        if let override = ProcessInfo.processInfo.environment["M3_SYNC_FOLDER"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.isWritableFile(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("M3 Tracker/Devices", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        publishIfChanged()
        refreshRemote()

        timer = Timer.scheduledTimer(withTimeInterval: syncInterval, repeats: true) { [weak self] _ in
            self?.publishIfChanged()
            self?.refreshRemote()
        }

        // A laptop is far more often put to sleep than quit.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.publishNow(synchronously: true)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRemote()
        }
    }

    // MARK: - Aggregates (main thread)

    var allMacsPoints: Double {
        MetricsStore.shared.totalPoints + remoteRecords.values.reduce(0) { $0 + $1.totalPoints }
    }

    var allMacsScrollPoints: Double {
        MetricsStore.shared.scrollPoints + remoteRecords.values.reduce(0) { $0 + ($1.scrollPoints ?? 0) }
    }

    /// This Mac plus every other Mac that has synced.
    var macCount: Int { remoteRecords.count + 1 }

    /// The other Macs' records to combine into charts and app rankings. Empty
    /// while iCloud Drive is off: the cached records are still held then, but
    /// nothing is keeping them current, so showing them would mislead.
    var activeRemoteRecords: [DeviceRecord] {
        isAvailable ? Array(remoteRecords.values) : []
    }

    /// This Mac's per-app data first (its app names win), then the other Macs'.
    var appSnapshots: [AppUsageSnapshot] {
        [AppUsageStore.shared.snapshot] + activeRemoteRecords.map(\.appSnapshot)
    }

    /// Every mouse's charge history, combined from this Mac and the others.
    var mouseHistories: [MouseChargeHistory] {
        let local = ChargeStore.shared.logs.values.sorted { $0.key < $1.key }
        return ChargeStore.histories(from: local + activeRemoteRecords.flatMap { $0.mice ?? [] })
    }

    // MARK: - Publishing this Mac's totals

    /// Writes this Mac's file now. `synchronously` waits (briefly) for the write,
    /// for quit and sleep, where the process may not get another chance.
    func publishNow(synchronously: Bool = false) {
        publish(makeLocalRecord(), synchronously: synchronously)
    }

    /// Skips the write when nothing has changed, so an idle Mac leaves iCloud alone.
    private func publishIfChanged() {
        let record = makeLocalRecord()
        guard record.content != lastPublished?.content else { return }
        publish(record, synchronously: false)
    }

    private func makeLocalRecord() -> DeviceRecord {
        let metrics = MetricsStore.shared
        let history = MileageHistoryStore.shared
        return DeviceRecord(
            deviceID: DeviceIdentity.deviceID,
            deviceName: DeviceIdentity.deviceName,
            updatedAt: Date(),
            trackingStartedAt: metrics.trackingStartedAt,
            totalPoints: metrics.totalPoints,
            keystrokes: metrics.keystrokes,
            leftClicks: metrics.leftClicks,
            rightClicks: metrics.rightClicks,
            hourly: history.hourlyBuckets,
            daily: history.dailyBuckets,
            apps: AppUsageStore.shared.allTime,
            appDays: AppUsageStore.shared.days,
            appNames: AppUsageStore.shared.names,
            // Left out entirely until a mouse has been seen, so files stay as
            // they were for anyone not using the feature.
            mice: ChargeStore.shared.logs.isEmpty ? nil : Array(ChargeStore.shared.logs.values),
            scrollPoints: metrics.scrollPoints,
            scrollHourly: MileageHistoryStore.scroll.hourlyBuckets,
            scrollDaily: MileageHistoryStore.scroll.dailyBuckets,
            diagnostics: InputDiagnostics.shared.snapshot
        )
    }

    private func publish(_ record: DeviceRecord, synchronously: Bool) {
        guard let folder = Self.syncFolder() else {
            setAvailable(false)
            return
        }
        lastPublished = record

        let done = DispatchSemaphore(value: 0)
        queue.async {
            defer { done.signal() }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(record.deviceID).json")
                let data = try Self.encoder.encode(record)
                try Self.coordinatedWrite(data, to: url)
            } catch {
                NSLog("M3 Tracker: couldn't publish to iCloud Drive: \(error.localizedDescription)")
                // Forget it was written, so the next tick tries again.
                DispatchQueue.main.async { self.lastPublished = nil }
            }
        }
        // Bounded, so a busy iCloud daemon can't hang quit or sleep.
        if synchronously { _ = done.wait(timeout: .now() + 2) }
    }

    // MARK: - Reading the other Macs

    func refreshRemote() {
        guard let folder = Self.syncFolder() else {
            setAvailable(false)
            return
        }
        let ownID = DeviceIdentity.deviceID

        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var records: [String: DeviceRecord] = [:]
            var downloading = Set<String>()

            for name in names {
                // iCloud Drive can evict a file to free space, leaving a
                // ".<name>.icloud" placeholder. Ask for it back, and keep using
                // the last-known record meanwhile so the total doesn't dip.
                if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    let id = String(real.dropLast(".json".count))
                    guard id != ownID else { continue }
                    try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                    downloading.insert(id)
                    continue
                }
                guard name.hasSuffix(".json") else { continue }
                guard let data = Self.coordinatedRead(folder.appendingPathComponent(name)),
                      let record = try? Self.decoder.decode(DeviceRecord.self, from: data),
                      record.deviceID != ownID else { continue }
                records[record.deviceID] = record
            }

            DispatchQueue.main.async {
                self.applyRemote(records, downloading: downloading)
            }
        }
    }

    private func applyRemote(_ fresh: [String: DeviceRecord], downloading: Set<String>) {
        var merged = fresh
        for id in downloading where merged[id] == nil {
            merged[id] = remoteRecords[id]
        }
        // A Mac whose file is gone (deleted by the user to retire it) drops out.
        remoteRecords = merged
        isAvailable = true

        if let data = try? Self.encoder.encode(remoteRecords) {
            UserDefaults.standard.set(data, forKey: Keys.remoteCache)
        }
        recordDiagnostics()
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    private func setAvailable(_ available: Bool) {
        guard available != isAvailable else { return }
        isAvailable = available
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }

    /// Mirrored into UserDefaults so the combined total can be checked from outside
    /// the app with `defaults read com.smanke.MouseMileage`.
    private func recordDiagnostics() {
        let miles = allMacsPoints / 72.0 / 12.0 / 5280.0
        UserDefaults.standard.set(miles, forKey: Keys.allMacsMiles)
        UserDefaults.standard.set(macCount, forKey: Keys.macCount)
    }

    // MARK: - Coordinated file access

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    private static func coordinatedRead(_ url: URL) -> Data? {
        var coordinationError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            data = try? Data(contentsOf: target)
        }
        return data
    }
}
