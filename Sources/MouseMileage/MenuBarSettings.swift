import Foundation

/// What the always-visible menu bar title counts, and how it's labelled.
enum MenuBarSettings {
    static let didChangeNotification = Notification.Name("MenuBarSettings.didChange")

    /// Prefixed to an All Macs total so it can't be mistaken for this Mac's.
    static let allMacsMarker = "Σ"

    private enum Key {
        static let showsAllMacs = "menuBarShowsAllMacs"
        static let marksAllMacs = "menuBarMarksAllMacs"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Key.marksAllMacs: true])
    }

    /// Show the combined total across every Mac instead of this Mac's own.
    /// Off by default, which matches how the menu bar worked before syncing.
    static var showsAllMacs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.showsAllMacs) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.showsAllMacs)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Prefix an All Macs total with "Σ". On by default.
    static var marksAllMacs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.marksAllMacs) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.marksAllMacs)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The menu bar title.
    ///
    /// Falls back to this Mac when iCloud Drive is off: the other Macs' last-known
    /// totals are still cached then, but with nothing keeping them current they'd
    /// quietly go stale. The marker only appears when the title really is the
    /// combined total, so it never labels a this-Mac-only figure as All Macs.
    static func title(showsAllMacs: Bool, marksAllMacs: Bool, isSyncAvailable: Bool,
                      thisMacPoints: Double, allMacsPoints: Double) -> String {
        guard showsAllMacs && isSyncAvailable else {
            return MetricsStore.distanceText(forPoints: thisMacPoints)
        }
        let distance = MetricsStore.distanceText(forPoints: allMacsPoints)
        return marksAllMacs ? "\(allMacsMarker) \(distance)" : distance
    }
}
