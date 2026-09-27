import Foundation

/// A card that can be placed in the menu dropdown, its flyout, both, or neither.
enum MenuCard: String, CaseIterable, Identifiable {
    case topApps, battery, todayByHour, byDay, yearToDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topApps: return "Top Apps"
        case .battery: return "Mileage per Charge"
        case .todayByHour: return "Today by Hour"
        case .byDay: return "By Day"
        case .yearToDate: return "Year to Date"
        }
    }

    /// The chosen cards in display order. Mileage per Charge only while that
    /// feature is on, wherever it's placed.
    static func visible(in chosen: Set<MenuCard>, batteryEnabled: Bool) -> [MenuCard] {
        allCases.filter { chosen.contains($0) && ($0 != .battery || batteryEnabled) }
    }
}

/// Which cards the menu shows, and which its More Charts flyout shows.
///
/// Every card stacked in the menu makes it taller than a laptop screen, so by
/// default the menu keeps only Today by Hour and the flyout has everything.
enum MenuLayoutSettings {
    static let didChangeNotification = Notification.Name("MenuLayoutSettings.didChange")

    private enum Key {
        static let menu = "menu.cards"
        static let flyout = "flyout.cards"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.menu: [MenuCard.todayByHour.rawValue],
            Key.flyout: MenuCard.allCases.map(\.rawValue),
        ])
    }

    static var menuCards: Set<MenuCard> {
        get { cards(forKey: Key.menu) }
        set { set(newValue, forKey: Key.menu) }
    }

    static var flyoutCards: Set<MenuCard> {
        get { cards(forKey: Key.flyout) }
        set { set(newValue, forKey: Key.flyout) }
    }

    /// Names this version doesn't know (from a newer version, say) are skipped.
    static func cards(from stored: [String]) -> Set<MenuCard> {
        Set(stored.compactMap(MenuCard.init(rawValue:)))
    }

    private static func cards(forKey key: String) -> Set<MenuCard> {
        cards(from: UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    private static func set(_ cards: Set<MenuCard>, forKey key: String) {
        // Stored in display order, so the defaults read naturally.
        UserDefaults.standard.set(MenuCard.allCases.filter(cards.contains).map(\.rawValue), forKey: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
