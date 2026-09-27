import XCTest
@testable import MouseMileage

final class AppRankingTests: XCTestCase {
    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private let now = ISO8601DateFormatter().date(from: "2026-09-10T15:00:00-04:00")!

    private func usage(_ points: Double, clicks: Int = 0, keys: Int = 0) -> AppUsage {
        AppUsage(points: points, clicks: clicks, keystrokes: keys)
    }

    private func snapshot(allTime: [String: AppUsage] = [:], days: [AppDay] = [],
                          names: [String: String] = [:]) -> AppUsageSnapshot {
        AppUsageSnapshot(allTime: allTime, days: days, names: names)
    }

    /// Same app on two Macs: one combined row, every metric summed.
    func testAllTimeSumsAcrossMacsByBundleID() {
        let thisMac = snapshot(allTime: ["com.adobe.Photoshop": usage(100, clicks: 3, keys: 5),
                                         "com.apple.Safari": usage(40)],
                               names: ["com.adobe.Photoshop": "Photoshop", "com.apple.Safari": "Safari"])
        let otherMac = snapshot(allTime: ["com.adobe.Photoshop": usage(50, clicks: 1, keys: 2),
                                          "com.google.Chrome": usage(70)],
                                names: ["com.adobe.Photoshop": "Adobe Photoshop 2026", "com.google.Chrome": "Chrome"])

        let rows = AppUsageStore.ranking(range: .allTime, snapshots: [thisMac, otherMac], calendar: newYork, now: now).rows

        XCTAssertEqual(rows.map(\.id), ["com.adobe.Photoshop", "com.google.Chrome", "com.apple.Safari"])
        XCTAssertEqual(rows[0].usage, usage(150, clicks: 4, keys: 7))
        XCTAssertEqual(rows[0].name, "Photoshop", "this Mac's name wins")
        XCTAssertEqual(rows[1].name, "Chrome", "falls back to another Mac's name")
    }

    func testTodayCountsOnlyTodaysUsage() {
        let local = snapshot(days: [
            AppDay(start: date("2026-09-09T00:00:00-04:00"), apps: ["a": usage(999)]),
            AppDay(start: date("2026-09-10T00:00:00-04:00"), apps: ["a": usage(10), "b": usage(20)]),
        ])
        let rows = AppUsageStore.ranking(range: .today, snapshots: [local], calendar: newYork, now: now).rows
        XCTAssertEqual(rows.map(\.id), ["b", "a"])
        XCTAssertEqual(rows.first { $0.id == "a" }?.usage.points, 10)
    }

    /// Seven days means today and the six before it; the eighth day falls out.
    func testSevenDaysIncludesSevenLocalDays() {
        let days = (0...7).map { offset -> AppDay in
            let start = newYork.date(byAdding: .day, value: -offset, to: newYork.startOfDay(for: now))!
            return AppDay(start: start, apps: ["a": usage(1)])
        }
        let rows = AppUsageStore.ranking(range: .sevenDays, snapshots: [snapshot(days: days)], calendar: newYork, now: now).rows
        XCTAssertEqual(rows.first?.usage.points, 7)
    }

    /// Another Mac's day is re-keyed onto this Mac's calendar, same rule as the charts:
    /// Tokyo's Sept 10 is mostly New York's Sept 9, so it isn't "today" here.
    func testRemoteDaysRekeyAcrossTimeZones() {
        let tokyo = snapshot(days: [AppDay(start: date("2026-09-10T00:00:00+09:00"), apps: ["a": usage(30)])])
        let losAngeles = snapshot(days: [AppDay(start: date("2026-09-10T00:00:00-07:00"), apps: ["a": usage(5)])])

        let today = AppUsageStore.ranking(range: .today, snapshots: [tokyo, losAngeles], calendar: newYork, now: now).rows
        XCTAssertEqual(today.first?.usage.points, 5, "only Los Angeles's Sept 10 lands on New York's Sept 10")

        let week = AppUsageStore.ranking(range: .sevenDays, snapshots: [tokyo, losAngeles], calendar: newYork, now: now).rows
        XCTAssertEqual(week.first?.usage.points, 35)
    }

    func testEmptyUsageIsDroppedAndTiesSortByName() {
        let local = snapshot(allTime: ["z": usage(5), "a": usage(5), "gone": AppUsage()],
                             names: ["z": "Zed", "a": "Alpha"])
        let rows = AppUsageStore.ranking(range: .allTime, snapshots: [local], calendar: newYork, now: now).rows
        XCTAssertEqual(rows.map(\.name), ["Alpha", "Zed"])
    }

    /// A clicks-only app still appears, below apps with mileage.
    func testAppsWithOnlyClicksOrKeystrokesAreKept() {
        let local = snapshot(allTime: ["typed": usage(0, keys: 50), "moved": usage(10)])
        let rows = AppUsageStore.ranking(range: .allTime, snapshots: [local], calendar: newYork, now: now).rows
        XCTAssertEqual(rows.map(\.id), ["moved", "typed"])
    }
}

final class AppUsageCompatibilityTests: XCTestCase {
    /// A file written by 1.14.0/1.14.1, before per-app data existed, must still decode.
    func testDeviceRecordWithoutAppFieldsDecodes() throws {
        let json = """
        {
          "schema": 1, "deviceID": "old", "deviceName": "Old Mac",
          "updatedAt": "2026-09-26T20:55:38Z", "trackingStartedAt": "2026-08-21T04:00:00Z",
          "totalPoints": 1000, "keystrokes": 1, "leftClicks": 2, "rightClicks": 3,
          "hourly": [], "daily": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(DeviceRecord.self, from: Data(json.utf8))

        XCTAssertNil(record.apps)
        XCTAssertEqual(record.appSnapshot, AppUsageSnapshot(allTime: [:], days: [], names: [:]))
    }

    func testDeviceRecordRoundTripsAppFields() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var record = DeviceRecord(deviceID: "x", deviceName: "X", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  trackingStartedAt: Date(timeIntervalSince1970: 1_780_000_000),
                                  totalPoints: 1, keystrokes: 0, leftClicks: 0, rightClicks: 0, hourly: [], daily: [])
        record.apps = ["com.apple.Safari": AppUsage(points: 12.5, clicks: 3, keystrokes: 4)]
        record.appDays = [AppDay(start: Date(timeIntervalSince1970: 1_789_948_800), apps: ["com.apple.Safari": AppUsage(points: 2)])]
        record.appNames = ["com.apple.Safari": "Safari"]

        XCTAssertEqual(try decoder.decode(DeviceRecord.self, from: encoder.encode(record)), record)
    }
}

final class AppUsageResetTests: XCTestCase {
    override func tearDown() {
        ["apps.allTime", "apps.days", "apps.names"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    /// Each Preferences reset clears only its own metric, per app.
    func testResetClearsOnlyTheChosenMetric() {
        let store = AppUsageStore.shared
        store.reset(points: true, clicks: true, keystrokes: true)
        store.record(points: 100)
        store.recordClick()
        store.recordKeystroke()

        store.reset(points: true, clicks: false, keystrokes: false)
        let key = AppUsageStore.unknownKey
        XCTAssertEqual(store.allTime[key], AppUsage(points: 0, clicks: 1, keystrokes: 1))
        XCTAssertEqual(store.days.last?.apps[key], AppUsage(points: 0, clicks: 1, keystrokes: 1))

        store.reset(points: false, clicks: true, keystrokes: true)
        XCTAssertNil(store.allTime[key], "an app with nothing left is dropped")
        XCTAssertNil(store.days.last?.apps[key])
    }
}
