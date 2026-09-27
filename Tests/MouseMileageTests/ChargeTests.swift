import XCTest
@testable import MouseMileage

final class ChargeSplittingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // on the hour
    private let pointsPerMile = 72.0 * 12 * 5280

    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
    private func sample(_ hours: Double, _ percent: Int, charging: Bool = false) -> BatterySample {
        BatterySample(date: at(hours), percent: percent, isCharging: charging)
    }
    private func bucket(_ hours: Double, miles: Double) -> MileageHistoryStore.Bucket {
        MileageHistoryStore.Bucket(start: at(hours), points: miles * pointsPerMile)
    }

    func testChargingFlagEndsAChargeAndUnpluggingStartsTheNext() {
        let samples = [sample(0, 100), sample(10, 70), sample(20, 40),
                       sample(21, 45, charging: true), sample(22, 100, charging: true), sample(23, 100)]
        let charges = ChargeStore.charges(samples: samples, movement: [])

        XCTAssertEqual(charges.count, 2)
        XCTAssertEqual(charges[0].start, at(0))
        XCTAssertEqual(charges[0].end, at(21))
        XCTAssertEqual(charges[0].startPercent, 100)
        XCTAssertEqual(charges[0].usedPercent, 60)
        XCTAssertEqual(charges[1].start, at(23))
        XCTAssertTrue(charges[1].isCurrent)
    }

    /// A recharge the app never saw (Mac asleep, or charged while disconnected)
    /// shows up as the level jumping back up.
    func testRiseOfTenPointsWithoutChargingFlagStartsANewCharge() {
        let samples = [sample(0, 90), sample(5, 30), sample(30, 95), sample(31, 94)]
        let charges = ChargeStore.charges(samples: samples, movement: [])

        XCTAssertEqual(charges.count, 2)
        XCTAssertEqual(charges[0].end, at(30))
        XCTAssertEqual(charges[0].usedPercent, 60)
        XCTAssertEqual(charges[1].startPercent, 95)
        XCTAssertEqual(charges[1].lowestPercent, 94)
    }

    func testSmallWobbleInTheReadingIsNotACharge() {
        let samples = [sample(0, 60), sample(1, 58), sample(2, 61), sample(3, 57), sample(4, 59)]
        let charges = ChargeStore.charges(samples: samples, movement: [])
        XCTAssertEqual(charges.count, 1)
        XCTAssertEqual(charges[0].lowestPercent, 57)
    }

    /// Readings from a charge still in progress raise the starting level
    /// rather than each counting as a new charge.
    func testLevelRisingBeforeAnyUseRaisesTheStart() {
        let samples = [sample(0, 35), sample(1, 60), sample(2, 100), sample(5, 90)]
        let charges = ChargeStore.charges(samples: samples, movement: [])
        XCTAssertEqual(charges.count, 1)
        XCTAssertEqual(charges[0].startPercent, 100)
        XCTAssertEqual(charges[0].usedPercent, 10)
    }

    func testReadingsWhileChargingBelongToNoCharge() {
        let charges = ChargeStore.charges(samples: [sample(0, 20, charging: true), sample(1, 80, charging: true)], movement: [])
        XCTAssertTrue(charges.isEmpty)
    }

    func testMovementIsAddedToTheChargeItHappenedIn() {
        let samples = [sample(0, 100), sample(10, 50), sample(10.5, 50, charging: true), sample(12.25, 100)]
        let movement = [bucket(1, miles: 2), bucket(9, miles: 3),
                        bucket(11, miles: 7),               // on the cable: neither charge
                        bucket(12, miles: 1),               // straddles the new start: the new charge
                        bucket(15, miles: 4)]
        let charges = ChargeStore.charges(samples: samples, movement: movement)

        XCTAssertEqual(charges[0].miles, 5, accuracy: 1e-9)
        XCTAssertEqual(charges[1].miles, 5, accuracy: 1e-9)
    }

    func testMilesPerFullChargeNormalizesAndNeedsTenPercent() {
        var charge = Charge(start: t0, end: nil, startPercent: 100, lowestPercent: 75, points: 5 * pointsPerMile)
        XCTAssertEqual(charge.milesPerFullCharge!, 20, accuracy: 1e-9, "5 mi on 25% → 20 mi per 100%")

        charge.lowestPercent = 91
        XCTAssertNil(charge.milesPerFullCharge, "9% used is too little to extrapolate from")
    }

    func testAverageCountsOnlyCompletedChargesWithAnEstimate() {
        let history = MouseChargeHistory(key: "k", name: "Mouse", charges: [
            Charge(start: at(0), end: at(1), startPercent: 100, lowestPercent: 50, points: 10 * pointsPerMile),  // 20
            Charge(start: at(2), end: at(3), startPercent: 100, lowestPercent: 95, points: 99 * pointsPerMile),  // too little used
            Charge(start: at(4), end: at(5), startPercent: 80, lowestPercent: 20, points: 18 * pointsPerMile),   // 30
            Charge(start: at(6), end: nil, startPercent: 100, lowestPercent: 50, points: 100 * pointsPerMile),   // current
        ], latest: nil)
        XCTAssertEqual(history.averageMilesPerFullCharge!, 25, accuracy: 1e-9)
    }
}

final class ChargeMergingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    /// An Easy-Switch mouse used on two Macs: one timeline of readings, and
    /// both Macs' movement in the same charge.
    func testTwoMacsCombineIntoOneCharge() {
        let desk = MouseLog(key: "logi:SN1", name: "MX Master 4",
                            movement: [.init(start: at(1), points: 1000)],
                            samples: [.init(date: at(0), percent: 100, isCharging: false),
                                      .init(date: at(8), percent: 80, isCharging: false)])
        let laptop = MouseLog(key: "logi:SN1", name: "MX Master 4 (laptop)",
                              movement: [.init(start: at(5), points: 500)],
                              samples: [.init(date: at(4), percent: 90, isCharging: false)])
        let other = MouseLog(key: "apple:xyz", name: "Magic Mouse",
                             samples: [.init(date: at(0), percent: 50, isCharging: false)])

        let histories = ChargeStore.histories(from: [desk, laptop, other])
        XCTAssertEqual(histories.map(\.key), ["apple:xyz", "logi:SN1"])
        let mx = histories[1]
        XCTAssertEqual(mx.name, "MX Master 4", "the first log's (this Mac's) name wins")
        XCTAssertEqual(mx.charges.count, 1)
        XCTAssertEqual(mx.charges[0].points, 1500)
        XCTAssertEqual(mx.charges[0].lowestPercent, 80)
        XCTAssertEqual(mx.latest?.percent, 80)
    }

    /// A reset on one Mac hides older data still held by another Mac.
    func testResetOnAnyMacHidesEarlierData() {
        let here = MouseLog(key: "k", name: "M", samples: [.init(date: at(10), percent: 70, isCharging: false)],
                            resetAt: at(10))
        let there = MouseLog(key: "k", name: "M",
                             movement: [.init(start: at(2), points: 999), .init(start: at(11), points: 5)],
                             samples: [.init(date: at(0), percent: 100, isCharging: false),
                                       .init(date: at(12), percent: 60, isCharging: false)])
        let history = ChargeStore.histories(from: [here, there])[0]
        XCTAssertEqual(history.charges.count, 1)
        XCTAssertEqual(history.charges[0].startPercent, 70)
        XCTAssertEqual(history.charges[0].points, 5)
    }

    func testDeviceRecordWithoutMiceDecodesAndRoundTripsWithThem() throws {
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var record = try decoder.decode(DeviceRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.mice)

        record.mice = [MouseLog(key: "logi:SN1", name: "MX", movement: [.init(start: at(0), points: 3)],
                                samples: [.init(date: at(0), percent: 60, isCharging: false)], resetAt: at(-1))]
        XCTAssertEqual(try decoder.decode(DeviceRecord.self, from: encoder.encode(record)), record)
    }
}

final class HIDPPTests: XCTestCase {
    /// Bytes an MX Master 4 sent over Bluetooth during the feasibility probe.
    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    func testRequestLayout() {
        XCTAssertEqual(HIDPP.request(deviceIndex: 0xFF, featureIndex: 0, function: 0, params: [0x10, 0x04]),
                       bytes("11 ff 00 0b 10 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(HIDPP.request(deviceIndex: 2, featureIndex: 9, function: 1).count, 20)
    }

    func testParsesUnifiedBatteryReply() {
        let reply = HIDPP.parse(bytes("11 ff 09 1b 3c 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))
        guard case let .response(deviceIndex, featureIndex, function, params)? = reply else {
            return XCTFail("expected a response, got \(String(describing: reply))")
        }
        XCTAssertEqual([deviceIndex, featureIndex, function], [0xFF, 9, 1])
        XCTAssertEqual(HIDPP.unifiedBattery(params), HIDPP.Battery(percent: 60, isCharging: false))
        XCTAssertEqual(HIDPP.unifiedBattery([0x2A, 0x04, 0x01]), HIDPP.Battery(percent: 42, isCharging: true))
        XCTAssertEqual(HIDPP.unifiedBattery([0x64, 0x08, 0x03]), HIDPP.Battery(percent: 100, isCharging: true), "charged, still plugged in")
    }

    func testParsesDeviceInfoAndSerial() {
        let info = HIDPP.deviceInfo(bytes("04 a7 2c b7 56 00 02 b0 42 00 00 00 00 04 01 00"))
        XCTAssertEqual(info?.unitID, "a72cb756")
        XCTAssertEqual(info?.hasSerial, true)
        XCTAssertEqual(HIDPP.serialNumber(Array("2603APHHBR48".utf8) + [0, 0, 0, 0]), "2603APHHBR48")
        XCTAssertNil(HIDPP.serialNumber([0, 0, 0, 0]))
    }

    func testIgnoresMotionReportsAndOtherAppsReplies() {
        XCTAssertNil(HIDPP.parse(bytes("02 00 00 e2 2f ff 00 00")), "ordinary mouse motion")
        XCTAssertNil(HIDPP.parse(bytes("11 ff 09 1a 3c 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00")), "another app's software ID")
    }

    func testBatteryEventAndErrors() {
        XCTAssertEqual(HIDPP.parse(bytes("11 ff 09 00 3b 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00")),
                       .event(deviceIndex: 0xFF, featureIndex: 9, function: 0, params: Array(bytes("3b 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))))
        XCTAssertEqual(HIDPP.parse(bytes("11 02 ff 00 0b 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00")),
                       .error(deviceIndex: 2, featureIndex: 0, function: 0))
        XCTAssertEqual(HIDPP.parse(bytes("10 03 8f 00 0b 09 00")),
                       .error(deviceIndex: 3, featureIndex: 0, function: 0), "HID++ 1.0 error from an unreachable slot")
        XCTAssertEqual(HIDPP.parse(bytes("10 02 41 04 72 45 40")), .receiverConnection(deviceIndex: 2))
    }

    func testMagicMouse() {
        XCTAssertEqual(MagicMouse.identify(vendorID: 0x004C, product: "Magic Mouse", serial: "AB:CD:EF:01")?.key, "apple:abcdef01")
        XCTAssertNil(MagicMouse.identify(vendorID: 0x004C, product: "Magic Trackpad", serial: "x"))
        XCTAssertNil(MagicMouse.identify(vendorID: 0x046D, product: "MX Master 4 M", serial: "x"))
        XCTAssertEqual(MagicMouse.battery(percent: NSNumber(value: 71), transport: "Bluetooth"), HIDPP.Battery(percent: 71, isCharging: false))
        XCTAssertEqual(MagicMouse.battery(percent: NSNumber(value: 71), transport: "USB")?.isCharging, true)
        XCTAssertNil(MagicMouse.battery(percent: nil, transport: "Bluetooth"))
    }

    func testDisplayNameDropsMacEditionSuffix() {
        XCTAssertEqual(LogitechMouse(deviceIndex: 0xFF, product: "MX Master 4 M").displayName, "MX Master 4")
        XCTAssertEqual(LogitechMouse(deviceIndex: 1, product: "M720 Triathlon").displayName, "M720 Triathlon")
        var mouse = LogitechMouse(deviceIndex: 0xFF, product: "MX Master 4 M")
        mouse.unitID = "a72cb756"
        XCTAssertEqual(mouse.key, "logi:unit-a72cb756")
        mouse.serial = "2603APHHBR48"
        XCTAssertEqual(mouse.key, "logi:2603APHHBR48")
    }
}
