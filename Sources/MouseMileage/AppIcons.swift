import AppKit
import UniformTypeIdentifiers

/// App icons by bundle ID, cached — the Top Apps list asks for the same few
/// icons every time the menu opens.
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The installed app's icon, or a generic app icon for one that isn't here
    /// (only used on another Mac, or recorded without a bundle ID).
    static func icon(for bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        cache[bundleID] = icon
        return icon
    }
}
