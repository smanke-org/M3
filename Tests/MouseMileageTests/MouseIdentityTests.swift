import XCTest
@testable import MouseMileage

final class MouseIdentityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)   // on the hour
    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }
    private func sample(_ hours: Double, _ percent: Int) -> BatterySample {
        BatterySample(date: at(hours), percent: percent, isCharging: false)
    }

    /// The real case: one MX Master 4 logged under its serial on one day and
    /// its unit ID the next.
    func testMergingAnAliasCombinesOneMouseLogs() {
        let bySerial = MouseLog(key: "logi:2603APHHBR48", name: "MX Master 4",
                                movement: [.init(start: at(0), points: 100), .init(start: at(1), points: 5)],
                                samples: [sample(0, 60)])
        let byUnit = MouseLog(key: "logi:unit-a72cb756", name: "MX Master 4",
                              movement: [.init(start: at(1), points: 7), .init(start: at(9), points: 1)],
                              samples: [sample(9, 60), sample(10, 55)])

        let merged = ChargeStore.merged(bySerial, into: byUnit)
        XCTAssertEqual(merged.key, "logi:unit-a72cb756")
        XCTAssertEqual(merged.aliases, ["logi:2603APHHBR48"])
        XCTAssertEqual(merged.movement.map(\.points), [100, 12, 1], "same hour summed, in time order")
        XCTAssertEqual(merged.samples.map(\.percent), [60, 55], "the repeated 60% reading is dropped")
        XCTAssertEqual(merged.samples.first?.date, at(0), "the earlier reading is kept")
    }

    /// A Mac still on 1.15.4 publishes the mouse under its serial; once any
    /// Mac has recorded the alias, both are one mouse.
    func testHistoriesGroupAnOldSerialKeyedLogThroughAliases() {
        let thisMac = MouseLog(key: "logi:unit-a72cb756", name: "MX Master 4",
                               movement: [.init(start: at(5), points: 10)],
                               samples: [sample(4, 80)], aliases: ["logi:2603APHHBR48"], serial: "2603APHHBR48")
        let olderMac = MouseLog(key: "logi:2603APHHBR48", name: "MX Master 4",
                                movement: [.init(start: at(1), points: 20)], samples: [sample(0, 90)])
        let other = MouseLog(key: "logi:unit-665e9e04", name: "Wireless Mouse MX Master 2S", samples: [sample(0, 50)])

        let histories = ChargeStore.histories(from: [olderMac, other, thisMac])
        XCTAssertEqual(histories.count, 2)
        let mx4 = histories.first { $0.key == "logi:unit-a72cb756" }!
        XCTAssertEqual(mx4.charges.first?.points, 30)
        XCTAssertEqual(mx4.charges.first?.startPercent, 90)
        XCTAssertEqual(mx4.serial, "2603APHHBR48")
        XCTAssertEqual(histories.first { $0.key == "logi:unit-665e9e04" }?.name, "MX Master 2S")
    }

    func testNewestNicknameWinsAcrossMacs() {
        let a = MouseLog(key: "k", name: "MX Master 4", nickname: "Desk", nicknameUpdatedAt: at(1))
        let b = MouseLog(key: "k", name: "MX Master 4", nickname: "Travel", nicknameUpdatedAt: at(2))
        let c = MouseLog(key: "k", name: "MX Master 4", nickname: nil, nicknameUpdatedAt: at(0))
        XCTAssertEqual(ChargeStore.histories(from: [a, b, c]).first?.nickname, "Travel")

        let cleared = MouseLog(key: "k", name: "MX Master 4", nickname: nil, nicknameUpdatedAt: at(3))
        XCTAssertNil(ChargeStore.histories(from: [a, b, cleared]).first?.nickname, "a later clear wins too")
    }

    func testLabelsAddASuffixOnlyToUnnamedDuplicates() {
        let labels = BatteryViewModel.labels(for: [
            ("a", "MX Master 4", nil, "BR48"),
            ("b", "MX Master 4", nil, "9X12"),
            ("c", "MX Master 2S", nil, "9E04"),
        ])
        XCTAssertEqual(labels, ["a": "MX Master 4 · BR48", "b": "MX Master 4 · 9X12", "c": "MX Master 2S"])

        let named = BatteryViewModel.labels(for: [
            ("a", "MX Master 4", "Desk", "BR48"),
            ("b", "MX Master 4", nil, "9X12"),
        ])
        XCTAssertEqual(named, ["a": "Desk", "b": "MX Master 4"], "once one is named, the other is unique")
    }

    func testModelNamesAndIDSuffix() {
        XCTAssertEqual(MouseName.model("MX Master 4 M"), "MX Master 4")
        XCTAssertEqual(MouseName.model("Wireless Mouse MX Master 2S"), "MX Master 2S")
        XCTAssertEqual(MouseName.model("M720 Triathlon"), "M720 Triathlon")
        XCTAssertEqual(MouseName.idSuffix(key: "logi:unit-a72cb756", serial: "2603APHHBR48"), "BR48")
        XCTAssertEqual(MouseName.idSuffix(key: "logi:unit-665e9e04", serial: nil), "9E04")
        XCTAssertEqual(MouseName.idSuffix(key: "apple:abcdef01", serial: nil), "EF01")
    }

    func testLogitechKeyIsTheUnitIDEvenWithASerial() {
        var mouse = LogitechMouse(deviceIndex: 0xFF, product: "MX Master 4 M")
        mouse.unitID = "a72cb756"
        mouse.serial = "2603APHHBR48"
        XCTAssertEqual(mouse.key, "logi:unit-a72cb756")
        XCTAssertEqual(mouse.legacyKey, "logi:2603APHHBR48")
    }

    func testOlderMouseLogDecodesWithoutNewFields() throws {
        let json = #"{"key":"logi:2603APHHBR48","name":"MX Master 4","movement":[],"samples":[]}"#
        let log = try JSONDecoder().decode(MouseLog.self, from: Data(json.utf8))
        XCTAssertNil(log.aliases)
        XCTAssertNil(log.nickname)
    }
}
