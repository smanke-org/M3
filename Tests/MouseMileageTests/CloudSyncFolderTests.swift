import XCTest
@testable import MouseMileage

/// Drives `CloudSync` against a scratch folder via `M3_SYNC_FOLDER`, so the real
/// iCloud Drive folder is never touched.
final class CloudSyncFolderTests: XCTestCase {
    private var folder: URL!

    /// Keys the stores write to `UserDefaults.standard` — the test runner's own
    /// domain here, not the app's — removed afterwards so nothing lingers.
    private let touchedKeys = [
        "totalPoints", "keystrokes", "leftClicks", "rightClicks", "trackingStartedAt",
        "history.hourly", "history.daily", "sync.remoteRecords",
        "diagnostics.allMacsMiles", "diagnostics.syncMacCount",
    ]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("M3SyncTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        setenv("M3_SYNC_FOLDER", folder.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("M3_SYNC_FOLDER")
        try? FileManager.default.removeItem(at: folder)
        touchedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private func write(_ record: DeviceRecord, as name: String? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: folder.appendingPathComponent(name ?? "\(record.deviceID).json"))
    }

    private func record(id: String, name: String, points: Double) -> DeviceRecord {
        DeviceRecord(
            deviceID: id, deviceName: name, updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            trackingStartedAt: Date(timeIntervalSince1970: 1_780_000_000),
            totalPoints: points, keystrokes: 0, leftClicks: 0, rightClicks: 0, hourly: [], daily: []
        )
    }

    /// Waits for one completed read of the folder.
    private func refresh() {
        let done = expectation(forNotification: CloudSync.didUpdateNotification, object: nil)
        CloudSync.shared.refreshRemote()
        wait(for: [done], timeout: 5)
    }

    func testReadsOtherMacsAndExcludesThisOne() throws {
        let sync = CloudSync.shared
        try write(record(id: "otherA", name: "Studio", points: 1_000))
        try write(record(id: "otherB", name: "Laptop", points: 500))
        // This Mac's own file must never be added on top of its live total.
        try write(record(id: DeviceIdentity.deviceID, name: "Me", points: 999_999))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("garbage.json"))

        refresh()

        XCTAssertEqual(Set(sync.remoteRecords.keys), ["otherA", "otherB"])
        XCTAssertEqual(sync.macCount, 3)
        XCTAssertEqual(sync.allMacsPoints, MetricsStore.shared.totalPoints + 1_500, accuracy: 0.001)
    }

    /// An evicted file keeps counting from its last-known record; a deleted one
    /// (a retired Mac the user removed) drops out.
    func testEvictedFileIsKeptAndDeletedFileIsDropped() throws {
        let sync = CloudSync.shared
        try write(record(id: "evictme", name: "Old iMac", points: 2_000))
        refresh()
        XCTAssertEqual(sync.remoteRecords["evictme"]?.totalPoints, 2_000)

        // iCloud Drive evicts "evictme.json", leaving ".evictme.json.icloud".
        try FileManager.default.removeItem(at: folder.appendingPathComponent("evictme.json"))
        try Data().write(to: folder.appendingPathComponent(".evictme.json.icloud"))
        refresh()
        XCTAssertEqual(sync.remoteRecords["evictme"]?.totalPoints, 2_000, "total must not dip while re-downloading")

        try FileManager.default.removeItem(at: folder.appendingPathComponent(".evictme.json.icloud"))
        refresh()
        XCTAssertNil(sync.remoteRecords["evictme"])
    }

    /// This Mac publishes a file the others can read back, under its own ID.
    func testPublishesThisMacsFile() throws {
        CloudSync.shared.publishNow(synchronously: true)

        let url = folder.appendingPathComponent("\(DeviceIdentity.deviceID).json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let written = try decoder.decode(DeviceRecord.self, from: Data(contentsOf: url))

        XCTAssertEqual(written.deviceID, DeviceIdentity.deviceID)
        XCTAssertEqual(written.totalPoints, MetricsStore.shared.totalPoints)
        XCTAssertFalse(written.deviceName.isEmpty)
    }

    /// The device ID is stable and hardware-derived, and never the raw UUID.
    func testDeviceIDIsStableAndHashed() {
        XCTAssertEqual(DeviceIdentity.deviceID, DeviceIdentity.deviceID)
        XCTAssertEqual(DeviceIdentity.deviceID.count, 16)
        XCTAssertFalse(DeviceIdentity.deviceID.contains("-"), "must not be a raw UUID")
    }
}
