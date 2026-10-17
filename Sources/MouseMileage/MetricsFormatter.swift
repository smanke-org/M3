import Foundation

/// Grouped number formatting ("19,330.8" rather than "19330.8"), so long
/// counts and distances stay readable at a glance. Locale-aware, so the
/// separator matches the user's region rather than always being a comma.
enum MetricsFormatter {
    private static func makeFormatter(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }

    private static let whole = makeFormatter(fractionDigits: 0)
    private static let oneDecimal = makeFormatter(fractionDigits: 1)
    private static let twoDecimals = makeFormatter(fractionDigits: 2)
    private static let threeDecimals = makeFormatter(fractionDigits: 3)

    /// Whole counts: keystrokes, clicks.
    static func count(_ value: Int) -> String {
        whole.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Tenths, as feet are shown.
    static func tenths(_ value: Double) -> String {
        oneDecimal.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// Hundredths, as miles are shown.
    static func hundredths(_ value: Double) -> String {
        twoDecimals.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    /// Thousandths, as the menu's live totals show miles.
    static func thousandths(_ value: Double) -> String {
        threeDecimals.string(from: NSNumber(value: value)) ?? String(format: "%.3f", value)
    }
}
