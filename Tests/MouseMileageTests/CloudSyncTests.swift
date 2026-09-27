import XCTest
@testable import MouseMileage

final class MergeTests: XCTestCase {
    typealias Bucket = MileageHistoryStore.Bucket

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    /// Two Macs in the same time zone: same buckets simply add.
    func testSameZoneBucketsSum() {
        let newYork = calendar("America/New_York")
        let hour = date("2026-09-10T14:00:00-04:00")
        let merged = MileageHistoryStore.merge(
            [[Bucket(start: hour, points: 100)], [Bucket(start: hour, points: 40)]],
            unit: .hour, calendar: newYork
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.start, hour)
        XCTAssertEqual(merged.first?.points, 140)
    }

    /// Merging never alters a Mac's own buckets on its own calendar.
    func testOwnBucketsAreUnchanged() {
        let newYork = calendar("America/New_York")
        let days = [
            Bucket(start: date("2026-09-08T00:00:00-04:00"), points: 1),
            Bucket(start: date("2026-09-09T00:00:00-04:00"), points: 2),
            // Fall-back day is 25 hours long; its midpoint must still land in it.
            Bucket(start: date("2026-11-01T00:00:00-04:00"), points: 3),
        ]
        let merged = MileageHistoryStore.merge([days], unit: .day, calendar: newYork)
        XCTAssertEqual(merged, days)
    }

    /// A Mac in another zone has different day boundaries. Each remote day goes to
    /// the local day it overlaps most, rather than splitting a day in two.
    func testRemoteDaysRebucketAcrossTimeZones() {
        let newYork = calendar("America/New_York")
        let localDay = date("2026-09-10T00:00:00-04:00")
        let losAngelesDay = date("2026-09-10T00:00:00-07:00")   // 03:00 in New York, same date
        let tokyoDay = date("2026-09-10T00:00:00+09:00")        // 11:00 the *previous* day in New York

        let merged = MileageHistoryStore.merge(
            [[Bucket(start: localDay, points: 100)],
             [Bucket(start: losAngelesDay, points: 50)],
             [Bucket(start: tokyoDay, points: 30)]],
            unit: .day, calendar: newYork
        )

        let byStart = Dictionary(uniqueKeysWithValues: merged.map { ($0.start, $0.points) })
        XCTAssertEqual(byStart[localDay], 150, "Los Angeles's Sept 10 is mostly New York's Sept 10")
        // Tokyo's Sept 10 runs 11:00 Sept 9 → 11:00 Sept 10 New York time: 13 of its 24 hours are Sept 9.
        XCTAssertEqual(byStart[date("2026-09-09T00:00:00-04:00")], 30)
        XCTAssertEqual(merged.count, 2)
    }

    /// Half-hour offsets don't line up with local hours either.
    func testRemoteHoursRebucketAcrossHalfHourOffset() {
        let newYork = calendar("America/New_York")
        let indiaHour = date("2026-09-10T10:00:00+05:30")       // 00:30 in New York
        let merged = MileageHistoryStore.merge([[Bucket(start: indiaHour, points: 7)]], unit: .hour, calendar: newYork)
        XCTAssertEqual(merged.first?.start, date("2026-09-10T01:00:00-04:00"))
        XCTAssertEqual(merged.first?.points, 7)
    }

    func testMergeOutputIsSortedAndEmptyInputIsEmpty() {
        let newYork = calendar("America/New_York")
        XCTAssertTrue(MileageHistoryStore.merge([], unit: .day, calendar: newYork).isEmpty)
        XCTAssertTrue(MileageHistoryStore.merge([[], []], unit: .hour, calendar: newYork).isEmpty)

        let later = Bucket(start: date("2026-09-10T15:00:00-04:00"), points: 1)
        let earlier = Bucket(start: date("2026-09-10T09:00:00-04:00"), points: 1)
        let merged = MileageHistoryStore.merge([[later], [earlier]], unit: .hour, calendar: newYork)
        XCTAssertEqual(merged.map(\.start), [earlier.start, later.start])
    }
}

final class DeviceRecordTests: XCTestCase {
    private func sampleRecord(updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> DeviceRecord {
        DeviceRecord(
            deviceID: "abc123",
            deviceName: "Test Mac",
            updatedAt: updatedAt,
            trackingStartedAt: Date(timeIntervalSince1970: 1_780_000_000),
            totalPoints: 1_234_567.5,
            keystrokes: 42,
            leftClicks: 7,
            rightClicks: 3,
            hourly: [.init(start: Date(timeIntervalSince1970: 1_789_999_200), points: 10)],
            daily: [.init(start: Date(timeIntervalSince1970: 1_789_948_800), points: 20)]
        )
    }

    /// The file format other Macs read: must survive a round trip exactly.
    func testRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = sampleRecord()
        let decoded = try decoder.decode(DeviceRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.schema, 1)
    }

    /// Publishing is skipped when nothing changed; a new timestamp alone isn't a change.
    func testContentIgnoresTimestamp() {
        let a = sampleRecord(updatedAt: Date(timeIntervalSince1970: 1))
        let b = sampleRecord(updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.content, b.content)

        var moved = b
        moved.totalPoints += 1
        XCTAssertNotEqual(a.content, moved.content)
    }
}

final class DistanceTextTests: XCTestCase {
    /// Under a mile shows feet to tenths; a mile or more shows miles to hundredths.
    func testFeetUnderAMileMilesAbove() {
        let pointsPerFoot = 72.0 * 12.0
        let pointsPerMile = pointsPerFoot * 5280

        XCTAssertEqual(MetricsStore.distanceText(forPoints: 1_000 * pointsPerFoot),
                       "\(MetricsFormatter.tenths(1_000)) ft")
        XCTAssertEqual(MetricsStore.distanceText(forPoints: 5_279.9 * pointsPerFoot),
                       "\(MetricsFormatter.tenths(5_279.9)) ft")
        XCTAssertEqual(MetricsStore.distanceText(forPoints: pointsPerMile),
                       "\(MetricsFormatter.hundredths(1)) mi")
        XCTAssertEqual(MetricsStore.distanceText(forPoints: 12.4 * pointsPerMile),
                       "\(MetricsFormatter.hundredths(12.4)) mi")
    }
}

final class MenuBarTitleTests: XCTestCase {
    private let pointsPerMile = 72.0 * 12.0 * 5280
    private var thisMac: Double { 10 * pointsPerMile }
    private var allMacs: Double { 25 * pointsPerMile }

    private func title(allMacs showsAll: Bool, marked: Bool, available: Bool) -> String {
        MenuBarSettings.title(showsAllMacs: showsAll, marksAllMacs: marked, isSyncAvailable: available,
                              thisMacPoints: thisMac, allMacsPoints: allMacs)
    }

    func testShowsChosenTotalWithOptionalMarker() {
        let ten = MetricsStore.distanceText(forPoints: thisMac)
        let twentyFive = MetricsStore.distanceText(forPoints: allMacs)

        XCTAssertEqual(title(allMacs: false, marked: true, available: true), ten, "This Mac is never marked")
        XCTAssertEqual(title(allMacs: true, marked: true, available: true), "Σ \(twentyFive)")
        XCTAssertEqual(title(allMacs: true, marked: false, available: true), twentyFive)
    }

    /// With sync off the title falls back to this Mac — and must not carry the
    /// marker, or it would label this Mac's own figure as the combined total.
    func testFallsBackToThisMacUnmarkedWhenSyncIsOff() {
        let ten = MetricsStore.distanceText(forPoints: thisMac)
        XCTAssertEqual(title(allMacs: true, marked: true, available: false), ten)
        XCTAssertEqual(title(allMacs: true, marked: false, available: false), ten)
    }
}
