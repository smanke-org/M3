import Foundation

/// What the always-visible menu bar title counts.
enum MenuBarSettings {
    static let didChangeNotification = Notification.Name("MenuBarSettings.didChange")

    private enum Key {
        static let showsAllMacs = "menuBarShowsAllMacs"
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

    /// The points the title should show. Falls back to this Mac when iCloud
    /// Drive is off: the other Macs' last-known totals are still cached then,
    /// but with nothing keeping them current they'd quietly go stale.
    static func titlePoints(showsAllMacs: Bool, isSyncAvailable: Bool, thisMac: Double, allMacs: Double) -> Double {
        showsAllMacs && isSyncAvailable ? allMacs : thisMac
    }
}
