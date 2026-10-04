import AppKit

/// An optional Dock icon, so Preferences can be reached by right-clicking it.
///
/// Off by default: this is a menu bar app, and it stays in the menu bar either
/// way. macOS only shows an app's own Dock-menu items while the app is running
/// with a Dock icon, which is why this is a setting rather than always there.
enum DockIcon {
    private static let key = "showInDock"

    static var isShown: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Sets the activation policy to match the setting. `keepInFront` is a
    /// window to keep visible when the icon goes away (the Preferences window
    /// the setting was changed from), since leaving the Dock deactivates the app.
    static func apply(keepInFront window: NSWindow? = nil) {
        if isShown {
            NSApp.setActivationPolicy(.regular)
        } else {
            // Going back to .accessory while the app is active doesn't take if
            // done synchronously; a runloop turn later it does.
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
                guard let window, window.isVisible else { return }
                // macOS refuses a plain activate once the app has left the Dock.
                window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
            }
        }
    }

    /// The Dock icon's right-click menu: Preferences….
    static func menu(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Preferences…", action: action, keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        return menu
    }

    /// A standard app menu for while the app has a Dock icon (and so a menu
    /// bar of its own): About, Preferences… on ⌘,, Hide and Quit.
    static func mainMenu(appName: String, target: AnyObject, preferences: Selector) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: preferences, keyEquivalent: ",")
        prefs.target = target
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        return main
    }
}
