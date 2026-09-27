import AppKit
import IOKit.hid

/// Finds Logitech mice and Apple Magic Mice, reads their batteries, and knows
/// which of them is moving the pointer, for mileage per charge.
///
/// Off until the user turns it on in Preferences: opening a mouse's HID device
/// needs Input Monitoring permission, and asking for that unprompted would be
/// a surprise for a feature most people may never use.
final class MouseBatteryMonitor {
    static let shared = MouseBatteryMonitor()
    static let didChangeNotification = Notification.Name("MouseBatteryMonitor.didChange")

    struct ConnectedMouse: Equatable {
        var key: String
        var name: String
        var battery: HIDPP.Battery?
    }

    enum Status: Equatable {
        case off
        /// On, but Input Monitoring hasn't been granted (or was denied).
        case needsPermission
        /// Granted, yet the devices still won't open: macOS applies a new
        /// Input Monitoring grant to a process only after it relaunches.
        case needsRelaunch
        case running
    }

    private(set) var status: Status = .off
    /// Mice connected now, by key.
    private(set) var connected: [String: ConnectedMouse] = [:]

    private static let enabledKey = "battery.enabled"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private var hidppManager: IOHIDManager?
    private var motionManager: IOHIDManager?
    private var transports: [UInt64: LogitechTransport] = [:]
    /// Magic Mice by the device's owner ID, for polling and removal.
    private var magicMice: [UInt64: (device: IOHIDDevice, key: String)] = [:]
    /// Which mouse a motion report's device belongs to. A Bluetooth mouse's
    /// motion and HID++ share one device; a receiver's mouse interface and its
    /// HID++ interface share a location ID.
    private var motionOwners: [UInt64: String] = [:]
    /// `motionOwners` by device object: motion reports arrive hundreds of
    /// times a second, too often to look up device properties for each.
    private var motionKeyCache: [ObjectIdentifier: String] = [:]
    private var lastMotionKey: String?
    private var lastMotionTime: TimeInterval = 0
    private var pollTimer: Timer?
    private var permissionTimer: Timer?

    private static let pollInterval: TimeInterval = 300
    /// How recently a mouse must have reported motion for a pointer move to be
    /// credited to it. Motion reports arrive every few milliseconds while moving.
    private static let motionWindow: TimeInterval = 0.1

    private init() {}

    // MARK: - On and off

    /// Called at launch: resumes tracking if the user turned it on before.
    func startIfEnabled() {
        guard isEnabled else { return }
        resume()
    }

    /// Turning on asks for Input Monitoring, once; macOS shows the prompt.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            resume()
        } else {
            stop()
            setStatus(.off)
        }
    }

    private func resume() {
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            setStatus(.needsPermission)
            waitForPermission()
            return
        }
        start()
    }

    /// The grant happens in System Settings, so look for it rather than
    /// making the user come back and press something.
    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled,
                  IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
            self.permissionTimer?.invalidate()
            self.permissionTimer = nil
            self.start()
        }
    }

    static func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Devices

    private func start() {
        guard hidppManager == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()

        let hidpp = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(hidpp, [
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF43],   // Bluetooth
            [kIOHIDVendorIDKey: 0x046D, kIOHIDDeviceUsagePageKey: 0xFF00],   // receivers, USB
        ] as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(hidpp, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MouseBatteryMonitor>.fromOpaque(context).takeUnretainedValue().addLogitech(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(hidpp, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MouseBatteryMonitor>.fromOpaque(context).takeUnretainedValue().removeLogitech(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(hidpp, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let motion = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(motion, [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse,
        ] as CFDictionary)
        IOHIDManagerSetInputValueMatching(motion, [kIOHIDElementUsagePageKey: kHIDPage_GenericDesktop] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(motion, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MouseBatteryMonitor>.fromOpaque(context).takeUnretainedValue().addPointingDevice(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(motion, { context, _, _, device in
            guard let context else { return }
            Unmanaged<MouseBatteryMonitor>.fromOpaque(context).takeUnretainedValue().removePointingDevice(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(motion, { context, _, _, value in
            guard let context else { return }
            Unmanaged<MouseBatteryMonitor>.fromOpaque(context).takeUnretainedValue().motion(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(motion, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let hidppResult = IOHIDManagerOpen(hidpp, IOOptionBits(kIOHIDOptionsTypeNone))
        let motionResult = IOHIDManagerOpen(motion, IOOptionBits(kIOHIDOptionsTypeNone))
        hidppManager = hidpp
        motionManager = motion
        NSLog("M3 Tracker: mouse battery managers opened: HID++ 0x%08x, motion 0x%08x", hidppResult, motionResult)

        if hidppResult == kIOReturnNotPermitted || motionResult == kIOReturnNotPermitted {
            stop()
            setStatus(.needsRelaunch)
            return
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        setStatus(.running)
    }

    private func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        transports.values.forEach { $0.stop() }
        transports.removeAll()
        magicMice.removeAll()
        motionOwners.removeAll()
        motionKeyCache.removeAll()
        connected.removeAll()
        lastMotionKey = nil
        for manager in [hidppManager, motionManager].compactMap({ $0 }) {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidppManager = nil
        motionManager = nil
        recordDiagnostics()
    }

    private func poll() {
        transports.values.forEach { $0.poll() }
        for (_, mouse) in magicMice { readMagicMouse(mouse.device, key: mouse.key) }
    }

    /// Location ID where there is one (shared by a receiver's interfaces),
    /// otherwise the registry entry. Stable for as long as the device is attached.
    private static func ownerID(_ device: IOHIDDevice) -> UInt64 {
        if let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber {
            return location.uint64Value
        }
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func addLogitech(_ device: IOHIDDevice) {
        let owner = Self.ownerID(device)
        guard transports[owner] == nil else { return }
        let product = Self.string(device, kIOHIDProductKey) ?? ""
        // Bolt and Unifying receivers are named "USB Receiver" / "Unifying Receiver".
        // A wired Logitech mouse also uses page 0xFF00, but answers as itself.
        let isReceiver = product.localizedCaseInsensitiveContains("receiver")
        let transport = LogitechTransport(device: device, isReceiver: isReceiver)
        transport.onBattery = { [weak self] mouse, battery in
            self?.setMotionOwner(owner, mouse.key)
            self?.update(key: mouse.key, name: mouse.displayName, battery: battery)
        }
        transports[owner] = transport
        transport.start()
    }

    private func removeLogitech(_ device: IOHIDDevice) {
        let owner = Self.ownerID(device)
        guard let transport = transports.removeValue(forKey: owner) else { return }
        transport.stop()
        for mouse in transport.mice.values {
            connected[mouse.key] = nil
        }
        setMotionOwner(owner, nil)
        changed()
    }

    /// Every mouse-class device, for motion. Only Magic Mice are read here;
    /// Logitech mice arrive through `addLogitech`, and trackpads are ignored.
    private func addPointingDevice(_ device: IOHIDDevice) {
        guard let parsed = MagicMouse.identify(
            vendorID: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
            product: Self.string(device, kIOHIDProductKey),
            serial: Self.string(device, kIOHIDSerialNumberKey)
        ) else { return }
        let owner = Self.ownerID(device)
        magicMice[owner] = (device, parsed.key)
        setMotionOwner(owner, parsed.key)
        readMagicMouse(device, key: parsed.key)
    }

    private func removePointingDevice(_ device: IOHIDDevice) {
        let owner = Self.ownerID(device)
        guard let mouse = magicMice.removeValue(forKey: owner) else { return }
        setMotionOwner(owner, nil)
        connected[mouse.key] = nil
        changed()
    }

    private func readMagicMouse(_ device: IOHIDDevice, key: String) {
        let service = IOHIDDeviceGetService(device)
        func search(_ name: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, name as CFString, kCFAllocatorDefault,
                                            IOOptionBits(kIORegistryIterateRecursively))
        }
        let battery = MagicMouse.battery(percent: search("BatteryPercent"),
                                         transport: Self.string(device, kIOHIDTransportKey))
        let name = Self.string(device, kIOHIDProductKey) ?? "Magic Mouse"
        update(key: key, name: name, battery: battery)
    }

    private func update(key: String, name: String, battery: HIDPP.Battery?) {
        connected[key] = ConnectedMouse(key: key, name: name, battery: battery)
        if let battery {
            ChargeStore.shared.recordBattery(mouse: key, name: name, percent: battery.percent,
                                             isCharging: battery.isCharging)
        }
        changed()
    }

    // MARK: - Motion (hot path)

    private func motion(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usage = Int(IOHIDElementGetUsage(element))
        guard usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y, IOHIDValueGetIntegerValue(value) != 0 else { return }
        let device = IOHIDElementGetDevice(element)
        let id = ObjectIdentifier(device)
        let key: String
        if let cached = motionKeyCache[id] {
            key = cached
        } else {
            // Not cached while unknown: the mouse may not be identified yet.
            guard let owner = motionOwners[Self.ownerID(device)] else { return }
            motionKeyCache[id] = owner
            key = owner
        }
        lastMotionKey = key
        lastMotionTime = ProcessInfo.processInfo.systemUptime
    }

    private func setMotionOwner(_ owner: UInt64, _ key: String?) {
        guard motionOwners[owner] != key else { return }
        motionOwners[owner] = key
        motionKeyCache.removeAll()
    }

    /// The tracked mouse that is moving the pointer right now, if any. Nil for
    /// trackpad movement, so it never counts toward a mouse's charge.
    func movingMouseKey() -> String? {
        guard let key = lastMotionKey,
              ProcessInfo.processInfo.systemUptime - lastMotionTime < Self.motionWindow else { return nil }
        return key
    }

    // MARK: - Notifying

    private func setStatus(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        changed()
    }

    private func changed() {
        recordDiagnostics()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Readable with `defaults read com.smanke.MouseMileage`, to check what
    /// the app sees without opening its UI.
    private func recordDiagnostics() {
        let mice = connected.values.map { mouse -> [String: Any] in
            var entry: [String: Any] = ["key": mouse.key, "name": mouse.name]
            if let battery = mouse.battery {
                entry["percent"] = battery.percent
                entry["charging"] = battery.isCharging
            }
            return entry
        }
        UserDefaults.standard.set(mice, forKey: "diagnostics.batteryMice")
        UserDefaults.standard.set("\(status)", forKey: "diagnostics.batteryStatus")
    }
}

/// Apple Magic Mouse: identified by vendor and name, with its battery read
/// from properties macOS publishes in the I/O Registry.
enum MagicMouse {
    static func identify(vendorID: Int?, product: String?, serial: String?) -> (key: String, name: String)? {
        guard vendorID == 0x004C || vendorID == 0x05AC,
              let product, product.localizedCaseInsensitiveContains("mouse") else { return nil }
        let id = (serial?.isEmpty == false ? serial! : product)
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").lowercased()
        return ("apple:\(id)", product)
    }

    /// A cable connection means it's charging. `BatteryStatusFlags` also
    /// reports charging, but its bits aren't documented, so only the cable is
    /// relied on; a recharge done while disconnected shows up as a rising level,
    /// which the charge rule catches.
    static func battery(percent: Any?, transport: String?) -> HIDPP.Battery? {
        guard let percent = (percent as? NSNumber)?.intValue, (1...100).contains(percent) else { return nil }
        return HIDPP.Battery(percent: percent, isCharging: transport == "USB")
    }
}
