import AppKit
import ApplicationServices

/// Watches system-wide mouse movement, clicks, and keystrokes via AppKit's global
/// event monitor.
///
/// Mouse events arrive without any permission, but **key events only arrive if the
/// app is trusted for Accessibility** — and when it isn't, they are simply never
/// delivered, with no error. That asymmetry looks exactly like a broken keystroke
/// counter: mileage and clicks climb while keystrokes sit at zero. So trust is
/// tracked explicitly here and surfaced in Preferences rather than failing quietly.
final class EventMonitor {
    static let trustDidChangeNotification = Notification.Name("EventMonitor.trustDidChange")

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustTimer: Timer?
    private var wasTrusted = false

    /// Mirrored into `UserDefaults` so the trust state can be inspected from
    /// outside the app (`defaults read com.smanke.MouseMileage`). Undelivered
    /// key events leave no other trace, which makes this hard to diagnose
    /// without a channel that doesn't depend on reading the app's logs.
    static let trustedDefaultsKey = "diagnostics.accessibilityTrusted"

    /// Whether this app is currently trusted for Accessibility, which is what
    /// keystroke monitoring depends on.
    var isTrusted: Bool { AXIsProcessTrusted() }

    private func recordTrust(_ trusted: Bool) {
        UserDefaults.standard.set(trusted, forKey: EventMonitor.trustedDefaultsKey)
    }

    func requestPermissionIfNeeded() {
        let options: [String: Bool] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func start() {
        wasTrusted = isTrusted
        NSLog("M3 Tracker: Accessibility trusted = \(wasTrusted). Keystroke counting requires this.")
        recordTrust(wasTrusted)

        register()

        // Trust can be granted while the app is running, but a monitor registered
        // beforehand won't start receiving key events on its own — it has to be
        // registered again once trust is in place.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkTrustChange()
        }
    }

    private func checkTrustChange() {
        let trusted = isTrusted
        guard trusted != wasTrusted else { return }
        wasTrusted = trusted
        NSLog("M3 Tracker: Accessibility trust changed to \(trusted); re-registering event monitors.")
        recordTrust(trusted)

        unregister()
        register()
        NotificationCenter.default.post(name: EventMonitor.trustDidChangeNotification, object: nil)
    }

    private func register() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }

        // Local monitor covers events targeted at our own app's windows (e.g. the
        // preferences panel), so mileage/clicks/keystrokes are counted consistently
        // even while this app is frontmost. Return the event unmodified.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func stop() {
        trustTimer?.invalidate()
        trustTimer = nil
        unregister()
    }

    /// Opens the Accessibility list in System Settings, where the app has to be
    /// enabled for keystroke counting to work.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// NSScrollView's default line height, for wheels that scroll in lines.
    static let pointsPerScrollLine = 10.0

    /// How far a scroll event moves the content, in points. Trackpads and the
    /// Magic Mouse report points; a notched wheel reports lines.
    static func scrollDistance(dx: Double, dy: Double, precise: Bool) -> Double {
        let distance = (dx * dx + dy * dy).squareRoot()
        return precise ? distance : distance * pointsPerScrollLine
    }

    private func handle(_ event: NSEvent) {
        let store = MetricsStore.shared
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            // deltaX/deltaY reflect raw pointer movement regardless of whether it
            // came from a mouse or a trackpad, so both are counted identically.
            let dx = Double(event.deltaX)
            let dy = Double(event.deltaY)
            let distance = (dx * dx + dy * dy).squareRoot()
            store.addMovement(points: distance)
        case .leftMouseDown:
            store.incrementLeftClicks()
        case .rightMouseDown:
            store.incrementRightClicks()
        case .keyDown:
            store.incrementKeystrokes()
        case .scrollWheel:
            // Momentum events (the glide after a flick) count too: the
            // measure is how far the content moved.
            let distance = Self.scrollDistance(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                                               precise: event.hasPreciseScrollingDeltas)
            store.addScroll(points: distance, startsGesture: event.phase.contains(.began) || event.phase.contains(.mayBegin))
        default:
            break
        }
    }
}
