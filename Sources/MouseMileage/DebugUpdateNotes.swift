#if DEBUG
import AppKit

/// Debug builds only. `M3_DEBUG_UPDATE_NOTES=<folder>`, run from a test copy with its own
/// bundle identifier (so its settings are its own, not the installed app's): fetches the notes
/// of M3 Tracker's own releases, draws the update prompt, the What's New sheet Settings shows
/// after an automatic update, and Settings itself to PNGs, writes report.txt, and quits. It
/// starts nothing else: no counting, permission request, sync or updater.
@MainActor
enum DebugUpdateNotes {
    static func run(folder: String) {
        guard Bundle.main.bundleIdentifier != AppInfo.bundleIdentifier else {
            NSLog("M3Tracker: this test needs a copy with its own bundle identifier")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        let controller = PreferencesWindowController.shared
        func contentSize() -> CGSize {
            controller.debugWindow.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
        }

        Task {
            note("running \(AppInfo.version) as \(Bundle.main.bundleIdentifier ?? "-")")
            // The update prompt, as someone on 1.16.2 would see it offered 1.16.5.
            let notes = await ReleaseNotes.fetch(newAfter: "1.16.2", through: "1.16.5")
            note("notes fetched: \(notes.map { $0.version + ($0.isNew ? " new" : "") })")
            let alert = UpdateController.makeConfirmAlert(newVersion: "1.16.5", current: "1.16.2", notes: notes)
            alert.layout()
            alert.window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            render(alert.window, to: out.appending(path: "update-prompt.png"))
            note("buttons: \(alert.buttons.map { "\($0.title) key='\($0.keyEquivalent)'" })")
            note("reminder box: '\(alert.suppressionButton?.title ?? "none")' on by default: \(alert.suppressionButton?.state == .on)")
            alert.window.orderOut(nil)

            // A brand-new install shows nothing.
            WhatsNew.shared.noteLaunch(newInstall: true, autoInstalledFrom: nil)
            note("new install pending: \(String(describing: WhatsNew.shared.pending))")
            // What's New in Settings after an automatic update from the release before this one.
            let previous = notes.first { UpdateController.isNewer(AppInfo.version, than: $0.version) }?.version ?? "1.16.4"
            WhatsNew.shared.noteLaunch(newInstall: false, autoInstalledFrom: previous)
            note("auto-update from \(previous) pending: \(String(describing: WhatsNew.shared.pending))")
            controller.show()
            try? await Task.sleep(for: .seconds(4))
            render(controller.debugWindow?.attachedSheet, to: out.appending(path: "whats-new.png"))
            note("sheet shown: \(controller.debugWindow?.attachedSheet != nil)")
            if let window = controller.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }
            // OK with "Don't show this again" ticked puts it away for good.
            WhatsNew.shared.dismiss(forGood: true)
            note("after dismiss pending: \(String(describing: WhatsNew.shared.pending))")
            try? await Task.sleep(for: .seconds(1))
            render(controller.debugWindow, to: out.appending(path: "general.png"))
            let window = controller.debugWindow
            note("settings resizable: \(window?.styleMask.contains(.resizable) == true) min \(window?.contentMinSize ?? .zero) general content \(contentSize())")

            // Asked for from the What's New… button: this version's notes, no "Don't show" box.
            controller.debugSelect(.sync)
            try? await Task.sleep(for: .seconds(1.5))
            render(controller.debugWindow, to: out.appending(path: "sync.png"))
            note("sync natural content \(contentSize())")
            controller.showWhatsNew()
            try? await Task.sleep(for: .seconds(3))
            render(controller.debugWindow?.attachedSheet, to: out.appending(path: "whats-new-asked.png"))
            note("asked sheet shown: \(controller.debugWindow?.attachedSheet != nil)")
            if let window = controller.debugWindow, let sheet = window.attachedSheet { window.endSheet(sheet) }

            // Each tab opens at its own height until the user drags a size, then every tab uses that.
            PreferencesWindowController.chosenSize = NSSize(width: 640, height: 420)
            controller.debugSelect(.menu)
            try? await Task.sleep(for: .seconds(1.5))
            render(controller.debugWindow, to: out.appending(path: "menu-dragged.png"))
            note("menu after a chosen 640x420: \(contentSize())")
            note("done")
            QuitConfirmation.quitNow()
        }
    }

    private static func render(_ window: NSWindow?, to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
