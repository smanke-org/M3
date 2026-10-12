import Foundation

/// Update-related preferences. Kept alongside the other counters in
/// `UserDefaults`, so they survive restarts like everything else.
enum UpdateSettings {
    private enum Key {
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }

    static func registerDefaults() {}

    /// A version the user chose to skip. The launch check stays quiet about
    /// it; asking again on every launch would just be nagging. Checking
    /// manually still offers it.
    static var skippedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: Key.skippedUpdateVersion) }
        set { UserDefaults.standard.set(newValue, forKey: Key.skippedUpdateVersion) }
    }
}

/// What M3 does when a newer release appears.
enum UpdatePolicy: String, CaseIterable {
    /// Download, verify and install on its own, while the Mac isn't being used.
    case automatic
    /// Say so (menu item and notification) and wait for the user to choose.
    case ask
    /// Don't look for updates; Check for Updates still works.
    case off

    var title: String {
        switch self {
        case .automatic: return "Install automatically"
        case .ask: return "Ask me first"
        case .off: return "Don't check"
        }
    }

    static let key = "updatePolicy"

    static var current: UpdatePolicy {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let policy = UpdatePolicy(rawValue: raw) { return policy }
            // 1.15.17 and earlier had only "Check for updates when the app opens".
            if UserDefaults.standard.object(forKey: "checkForUpdatesAtLaunch") as? Bool == false { return .off }
            return .ask
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
