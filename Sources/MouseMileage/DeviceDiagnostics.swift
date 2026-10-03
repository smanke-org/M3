import ApplicationServices
import Foundation

/// A few facts about this Mac's copy of the app, published in its iCloud Drive
/// file so a problem on one Mac can be looked into from another: which version
/// is running, whether it has its permissions, and what input it's receiving.
struct DeviceDiagnostics: Codable, Equatable {
    var appVersion: String
    var launchedAt: Date
    var accessibilityTrusted: Bool
    /// Scroll events since launch, by kind: trackpad / Magic Mouse (points)
    /// and notched wheels (lines).
    var preciseScrollEvents: Int
    var wheelScrollEvents: Int
    /// For wheel events: lines reported, and the points macOS actually
    /// scrolled for them. Their ratio shows how far a line really goes.
    var wheelLines: Double
    var wheelPoints: Double
    var lastScrollAt: Date?
    var batteryStatus: String
    var batteryEvents: [String]
}

/// Counts what the event monitor sees. Main thread only, like the monitor.
final class InputDiagnostics {
    static let shared = InputDiagnostics()

    private let launchedAt = Date()
    private var preciseScrollEvents = 0
    private var wheelScrollEvents = 0
    private var wheelLines = 0.0
    private var wheelPoints = 0.0
    private var lastScrollAt: Date?

    private init() {}

    func recordScroll(precise: Bool, lines: Double, points: Double) {
        if precise {
            preciseScrollEvents += 1
        } else {
            wheelScrollEvents += 1
            wheelLines += lines
            wheelPoints += points
        }
        lastScrollAt = Date()
    }

    /// Rounded to the minute, so the synced file isn't rewritten for every
    /// scroll event's timestamp alone.
    var snapshot: DeviceDiagnostics {
        let defaults = UserDefaults.standard
        return DeviceDiagnostics(
            appVersion: AppInfo.version,
            launchedAt: launchedAt,
            accessibilityTrusted: AXIsProcessTrusted(),
            preciseScrollEvents: preciseScrollEvents,
            wheelScrollEvents: wheelScrollEvents,
            wheelLines: wheelLines.rounded(),
            wheelPoints: wheelPoints.rounded(),
            lastScrollAt: lastScrollAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded(.down) * 60) },
            batteryStatus: defaults.string(forKey: "diagnostics.batteryStatus") ?? "off",
            batteryEvents: Array((defaults.stringArray(forKey: "diagnostics.batteryEvents") ?? []).suffix(10))
        )
    }
}
