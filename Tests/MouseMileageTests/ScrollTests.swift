import XCTest
@testable import MouseMileage

final class ScrollTests: XCTestCase {
    func testScrollDistanceFromPreciseAndLineDeltas() {
        XCTAssertEqual(EventMonitor.scrollDistance(dx: 3, dy: -4, precise: true), 5, "trackpad deltas are points")
        XCTAssertEqual(EventMonitor.scrollDistance(dx: 0, dy: -2, precise: false), 20, "a wheel's lines are 10 pt each")
    }

    /// Data saved before 1.15.9, and other Macs' files, have no scrollPoints.
    func testAppUsageWithoutScrollDecodesAsZero() throws {
        let json = #"{"points": 12.5, "clicks": 3, "keystrokes": 4}"#
        let usage = try JSONDecoder().decode(AppUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage, AppUsage(points: 12.5, clicks: 3, keystrokes: 4, scrollPoints: 0))

        let withScroll = AppUsage(points: 1, scrollPoints: 7)
        XCTAssertEqual(try JSONDecoder().decode(AppUsage.self, from: JSONEncoder().encode(withScroll)), withScroll)
    }

    func testDeviceRecordRoundTripsScrollFields() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var record = DeviceRecord(deviceID: "x", deviceName: "X", updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                  trackingStartedAt: Date(timeIntervalSince1970: 1_780_000_000),
                                  totalPoints: 1, keystrokes: 0, leftClicks: 0, rightClicks: 0, hourly: [], daily: [])
        record.scrollPoints = 99
        record.scrollDaily = [.init(start: Date(timeIntervalSince1970: 1_789_948_800), points: 99)]
        XCTAssertEqual(try decoder.decode(DeviceRecord.self, from: encoder.encode(record)), record)
    }

    func testScrollHistoryIsSeparateFromPointerHistory() {
        MileageHistoryStore.shared.resetHistory()
        MileageHistoryStore.scroll.resetHistory()
        defer {
            MileageHistoryStore.shared.resetHistory()
            MileageHistoryStore.scroll.resetHistory()
        }
        MileageHistoryStore.scroll.recordMovement(points: 500)
        XCTAssertEqual(MileageHistoryStore.scroll.hourlyBuckets.map(\.points), [500])
        XCTAssertTrue(MileageHistoryStore.shared.hourlyBuckets.isEmpty)
    }

    func testSortByScroll() {
        let rows = [
            AppRanking.Row(id: "a", name: "Safari", usage: AppUsage(points: 90, scrollPoints: 10)),
            AppRanking.Row(id: "b", name: "Chrome", usage: AppUsage(points: 5, scrollPoints: 800)),
        ]
        XCTAssertEqual(AppSortColumn.sorted(rows, by: .scroll, ascending: false).map(\.id), ["b", "a"])
    }

    func testScrollResetLeavesOtherMetrics() {
        let store = AppUsageStore.shared
        store.reset(points: true, clicks: true, keystrokes: true, scroll: true)
        defer {
            store.reset(points: true, clicks: true, keystrokes: true, scroll: true)
            ["apps.allTime", "apps.days", "apps.names"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        store.record(points: 10)
        store.recordScroll(points: 40, startsGesture: true)
        let totalScroll = store.allTime.values.reduce(0) { $0 + $1.scrollPoints }
        XCTAssertEqual(totalScroll, 40)

        store.reset(points: false, clicks: false, keystrokes: false, scroll: true)
        XCTAssertEqual(store.allTime.values.reduce(0) { $0 + $1.scrollPoints }, 0)
        XCTAssertEqual(store.allTime.values.reduce(0) { $0 + $1.points }, 10)
    }
}
