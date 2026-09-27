import XCTest
@testable import MouseMileage

final class MenuLayoutTests: XCTestCase {
    override func tearDown() {
        ["menu.cards", "flyout.cards"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    /// Out of the box: only Today by Hour in the menu, everything in the flyout.
    func testDefaults() {
        MenuLayoutSettings.registerDefaults()
        XCTAssertEqual(MenuLayoutSettings.menuCards, [.todayByHour])
        XCTAssertEqual(MenuLayoutSettings.flyoutCards, Set(MenuCard.allCases))
    }

    func testChoicesRoundTripAndUnknownNamesAreSkipped() {
        MenuLayoutSettings.menuCards = [.yearToDate, .topApps]
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "menu.cards"), ["topApps", "yearToDate"], "stored in display order")
        XCTAssertEqual(MenuLayoutSettings.menuCards, [.topApps, .yearToDate])
        XCTAssertEqual(MenuLayoutSettings.cards(from: ["byDay", "someFutureCard"]), [.byDay])
    }

    func testVisibleKeepsDisplayOrderAndHidesBatteryWhenOff() {
        let chosen: Set<MenuCard> = [.yearToDate, .battery, .topApps]
        XCTAssertEqual(MenuCard.visible(in: chosen, batteryEnabled: false), [.topApps, .yearToDate])
        XCTAssertEqual(MenuCard.visible(in: chosen, batteryEnabled: true), [.topApps, .battery, .yearToDate])
    }
}
