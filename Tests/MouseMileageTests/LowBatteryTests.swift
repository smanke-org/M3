import XCTest
@testable import MouseMileage

final class LowBatteryTests: XCTestCase {
    private func battery(_ percent: Int, charging: Bool = false, critical: Bool = false) -> HIDPP.Battery {
        HIDPP.Battery(percent: percent, isCharging: charging, isCritical: critical)
    }

    func testWarnsOnceBelowFivePercent() {
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(5), alreadyWarned: false), .none, "5% is not below 5%")
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(4), alreadyWarned: false), .warn)
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(2), alreadyWarned: true), .none, "only once per discharge")
    }

    /// Coarse-stepped mice may never report under 5%, but do flag critical.
    func testCriticalFlagWarnsEvenAtACoarseLevel() {
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(10, critical: true), alreadyWarned: false), .warn)
    }

    func testChargingOrARechargeClearsTheWarning() {
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(3, charging: true), alreadyWarned: true), .clear)
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(40), alreadyWarned: true), .clear, "recharged while the app wasn't looking")
        XCTAssertEqual(LowBatteryPolicy.evaluate(battery(8), alreadyWarned: true), .none, "between the thresholds, no change")
    }

    func testDescriptionHasMakeAndModel() {
        XCTAssertEqual(LowBatteryPolicy.mouseDescription(key: "logi:unit-a72cb756", model: "MX Master 4", nickname: nil),
                       "Logitech MX Master 4")
        XCTAssertEqual(LowBatteryPolicy.mouseDescription(key: "apple:abcd", model: "Magic Mouse", nickname: nil),
                       "Apple Magic Mouse")
        XCTAssertEqual(LowBatteryPolicy.mouseDescription(key: "logi:unit-665e9e04", model: "MX Master 2S", nickname: "Desk"),
                       "Desk (Logitech MX Master 2S)")
    }

    func testUnifiedBatteryReadsTheCriticalFlag() {
        XCTAssertEqual(HIDPP.unifiedBattery([0x03, 0x01, 0x00])?.isCritical, true)
        XCTAssertEqual(HIDPP.unifiedBattery([0x3C, 0x08, 0x00])?.isCritical, false)
    }
}
