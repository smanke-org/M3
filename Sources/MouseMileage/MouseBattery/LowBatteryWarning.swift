import AppKit
import SwiftUI

/// When to warn about a mouse's battery. Pure, so it can be tested.
///
/// A mouse is warned about once per discharge: below 5% (or when it reports
/// itself critical, since some mice report their level in coarse steps), and
/// not again until it has been charged. Plugging it in, or a reading back up
/// at 15% or more (a recharge the app didn't see), clears that.
enum LowBatteryPolicy {
    static let thresholdPercent = 5
    static let rearmPercent = 15

    enum Action: Equatable {
        case warn
        /// It's charging or charged: take any warning down.
        case clear
        case none
    }

    static func evaluate(_ battery: HIDPP.Battery, alreadyWarned: Bool) -> Action {
        if battery.isCharging || battery.percent >= rearmPercent { return .clear }
        let low = battery.percent < thresholdPercent || battery.isCritical
        return low && !alreadyWarned ? .warn : .none
    }

    /// "Logitech MX Master 4", or "Desk (Logitech MX Master 4)" for a mouse
    /// the user has named.
    static func mouseDescription(key: String, model: String, nickname: String?) -> String {
        let make = key.hasPrefix("logi:") ? "Logitech" : (key.hasPrefix("apple:") ? "Apple" : nil)
        let makeAndModel = [make, model].compactMap { $0 }.joined(separator: " ")
        guard let nickname, !nickname.isEmpty else { return makeAndModel }
        return "\(nickname) (\(makeAndModel))"
    }
}

/// Shows a low-battery notice in the top-right corner, styled like
/// NetworkToggle's arrival panel: a small floating card under the menu bar that
/// never takes focus, so it can't interrupt typing. It stays until clicked.
/// Main thread only, like the battery monitor that drives it.
final class LowBatteryWarner {
    static let shared = LowBatteryWarner()

    private static let enabledKey = "battery.lowWarning"
    private static let warnedKey = "battery.lowWarned"

    /// On by default; the switch is in Preferences › Battery.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Mice already warned about this discharge. Kept across launches, so a
    /// relaunch doesn't warn again about a mouse that's still low.
    private var warned: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.warnedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Self.warnedKey) }
    }

    /// One panel per mouse, stacked down from the corner.
    private var panels: [String: NSPanel] = [:]
    private var order: [String] = []

    private init() {}

    func check(key: String, model: String, battery: HIDPP.Battery) {
        switch LowBatteryPolicy.evaluate(battery, alreadyWarned: warned.contains(key)) {
        case .clear:
            warned.remove(key)
            dismiss(key)
        case .warn:
            guard Self.isEnabled else { return }
            warned.insert(key)
            show(key: key, description: describe(key: key, model: model), percent: battery.percent)
        case .none:
            break
        }
    }

    /// From Preferences, so the notice can be seen without a flat battery.
    func preview() {
        show(key: "preview", description: "Logitech MX Master 4", percent: 3)
    }

    private func describe(key: String, model: String) -> String {
        let nickname = CloudSync.shared.mouseHistories.first { $0.key == key }?.nickname
        return LowBatteryPolicy.mouseDescription(key: key, model: model, nickname: nickname)
    }

    private func show(key: String, description: String, percent: Int) {
        dismiss(key)
        let view = LowBatteryNotice(mouse: description, percent: percent) { [weak self] in
            self?.dismiss(key)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        panels[key] = panel
        order.append(key)
        layout()
        panel.orderFrontRegardless()
    }

    private func dismiss(_ key: String) {
        guard let panel = panels.removeValue(forKey: key) else { return }
        panel.orderOut(nil)
        order.removeAll { $0 == key }
        layout()
    }

    /// Top right, just under the menu bar, where a notification would appear;
    /// a second notice sits below the first.
    private func layout() {
        guard let area = NSScreen.main?.visibleFrame else { return }
        var top = area.maxY - 12
        for key in order {
            guard let panel = panels[key] else { continue }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: top - size.height))
            top -= size.height + 8
        }
    }
}

struct LowBatteryNotice: View {
    let mouse: String
    let percent: Int
    let dismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        // The whole card is the button: a click anywhere clears it.
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "battery.0")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mouse battery low")
                        .fontWeight(.medium)
                    Text(mouse)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(percent)% left. Charge it soon.")
                        .font(.callout)
                    Text("Click to dismiss")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
            .brightness(isHovering ? 0.03 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Dismiss")
    }
}
