import Foundation
import IOKit.hid

/// One Logitech HID++ interface: a Bluetooth mouse itself, or a Bolt/Unifying
/// receiver with up to six paired devices behind it.
///
/// Requests go out one at a time; each waits for its reply, an error, or a
/// timeout (a device behind a receiver may be asleep). Everything runs on the
/// main run loop, like the rest of the app.
final class LogitechTransport {
    let device: IOHIDDevice
    let isReceiver: Bool
    /// Products and pairing slots found to be mice, keyed by device index.
    private(set) var mice: [UInt8: LogitechMouse] = [:]
    var onBattery: ((LogitechMouse, HIDPP.Battery) -> Void)?
    /// Short notes on identification, for the diagnostics log.
    var onEvent: ((String) -> Void)?

    /// Slots being identified now, slots that answered but aren't mice (a
    /// keyboard on the same receiver), and failed attempts per slot.
    private var identifying = Set<UInt8>()
    private var notMice = Set<UInt8>()
    private var failures: [UInt8: Int] = [:]
    /// A mouse that has just connected or woken often doesn't answer at first.
    /// Before 1.15.8 one unanswered request meant it was never picked up.
    private static let retryDelays: [TimeInterval] = [2, 5, 15, 30, 60]

    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private struct Pending {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let function: UInt8
        let params: [UInt8]
        let reply: ([UInt8]?) -> Void
    }
    private var queue: [Pending] = []
    private var inFlight: Pending?
    private var generation = 0

    init(device: IOHIDDevice, isReceiver: Bool) {
        self.device = device
        self.isReceiver = isReceiver
    }

    deinit {
        reportBuffer.deallocate()
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            guard let context else { return }
            let transport = Unmanaged<LogitechTransport>.fromOpaque(context).takeUnretainedValue()
            transport.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)

        if isReceiver {
            (1...6).forEach { identify(deviceIndex: $0) }
        } else {
            identify(deviceIndex: HIDPP.bluetoothDeviceIndex)
        }
    }

    func stop() {
        queue.removeAll()
        inFlight = nil
        generation += 1
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, nil, nil)
    }

    /// Re-reads every known mouse's battery.
    /// Re-reads batteries, and tries again to identify anything that hasn't
    /// answered yet. Runs every few minutes and after the Mac wakes.
    func poll() {
        let slots: [UInt8] = isReceiver ? Array(1...6) : [HIDPP.bluetoothDeviceIndex]
        for slot in slots where mice[slot] == nil && !notMice.contains(slot) {
            identify(deviceIndex: slot)
        }
        for mouse in mice.values {
            if mouse.hasSerial, mouse.serial == nil { readSerial(mouse) }
            readBattery(mouse)
        }
    }

    /// A serial number that didn't come back when the mouse connected is
    /// asked for again, so its earlier key can still be merged in.
    private func readSerial(_ mouse: LogitechMouse) {
        guard let index = mouse.featureIndex[.deviceInformation] else { return }
        send(mouse.deviceIndex, index, function: 2) { [weak self] params in
            guard let serial = params.flatMap(HIDPP.serialNumber) else { return }
            self?.mice[mouse.deviceIndex]?.serial = serial
        }
    }

    // MARK: - Identification

    /// Finds the device's features, and keeps it only if it's a mouse with a
    /// battery we can read.
    private func identify(deviceIndex: UInt8) {
        guard !identifying.contains(deviceIndex) else { return }
        identifying.insert(deviceIndex)
        var mouse = LogitechMouse(deviceIndex: deviceIndex, product: property(kIOHIDProductKey) ?? "Logitech mouse")
        let features: [HIDPP.Feature] = [.deviceInformation, .deviceNameType, .unifiedBattery, .batteryStatus]
        var remaining = features

        func lookupNext() {
            guard let feature = remaining.first else { return identifyType() }
            remaining.removeFirst()
            send(deviceIndex, 0, function: 0, params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)]) { params in
                // A device that doesn't answer the root feature is absent or asleep.
                guard let params else { return failed("no answer to feature lookup") }
                if params[0] != 0 { mouse.featureIndex[feature] = params[0] }
                lookupNext()
            }
        }

        func identifyType() {
            guard let index = mouse.featureIndex[.deviceNameType] else {
                // No type to ask for: fall back to what the HID interface says.
                mouse.isPointingDevice = !isReceiver && primaryUsageIsMouse
                return readIdentity()
            }
            send(deviceIndex, index, function: 2) { params in
                // No answer is a failure to retry, not a verdict that it isn't a mouse.
                guard let params else { return failed("no answer to device type") }
                mouse.isPointingDevice = HIDPP.DeviceType(rawValue: params[0])?.isPointingDevice ?? false
                readIdentity()
            }
        }

        func readIdentity() {
            guard mouse.isPointingDevice,
                  mouse.featureIndex[.unifiedBattery] != nil || mouse.featureIndex[.batteryStatus] != nil,
                  let infoIndex = mouse.featureIndex[.deviceInformation] else {
                identifying.remove(deviceIndex)
                notMice.insert(deviceIndex)
                onEvent?("\(mouse.product) slot \(deviceIndex): not a mouse with a readable battery")
                return
            }
            send(deviceIndex, infoIndex, function: 0) { params in
                guard let info = params.flatMap(HIDPP.deviceInfo) else { return failed("no answer to device info") }
                mouse.unitID = info.unitID
                mouse.hasSerial = info.hasSerial
                guard info.hasSerial else { return readName() }
                self.send(deviceIndex, infoIndex, function: 2) { params in
                    mouse.serial = params.flatMap(HIDPP.serialNumber)
                    readName()
                }
            }
        }

        // A receiver's product name is the receiver's, so ask the mouse its own.
        func readName() {
            guard isReceiver, let nameIndex = mouse.featureIndex[.deviceNameType] else { return finish() }
            send(deviceIndex, nameIndex, function: 0) { params in
                guard let length = params?.first, length > 0 else { return finish() }
                var name: [UInt8] = []
                func readChunk() {
                    guard name.count < Int(length) else {
                        mouse.product = String(bytes: name, encoding: .utf8) ?? mouse.product
                        return finish()
                    }
                    self.send(deviceIndex, nameIndex, function: 1, params: [UInt8(name.count)]) { params in
                        guard let params else { return finish() }
                        let chunk = params.prefix(Int(length) - name.count).prefix { $0 != 0 }
                        guard !chunk.isEmpty else { return finish() }
                        name += chunk
                        readChunk()
                    }
                }
                readChunk()
            }
        }

        func finish() {
            identifying.remove(deviceIndex)
            failures[deviceIndex] = nil
            mice[deviceIndex] = mouse
            onEvent?("identified \(mouse.product) (\(mouse.key))")
            readBattery(mouse)
        }

        func failed(_ reason: String) {
            identifying.remove(deviceIndex)
            // Empty receiver slots never answer; they're retried by poll() and
            // when the receiver reports a device connecting, not on a timer.
            guard !isReceiver else { return }
            let attempt = (failures[deviceIndex] ?? 0) + 1
            failures[deviceIndex] = attempt
            let retry = attempt <= Self.retryDelays.count ? Self.retryDelays[attempt - 1] : nil
            onEvent?("\(mouse.product): \(reason), attempt \(attempt)" + (retry.map { ", retrying in \(Int($0)) s" } ?? ", next try at the next poll"))
            guard let retry else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + retry) { [weak self] in
                guard let self, self.mice[deviceIndex] == nil else { return }
                self.identify(deviceIndex: deviceIndex)
            }
        }

        lookupNext()
    }

    private func readBattery(_ mouse: LogitechMouse) {
        if let index = mouse.featureIndex[.unifiedBattery] {
            send(mouse.deviceIndex, index, function: 1) { [weak self] params in
                guard let battery = params.flatMap(HIDPP.unifiedBattery) else { return }
                self?.onBattery?(mouse, battery)
            }
        } else if let index = mouse.featureIndex[.batteryStatus] {
            send(mouse.deviceIndex, index, function: 0) { [weak self] params in
                guard let battery = params.flatMap(HIDPP.batteryStatus) else { return }
                self?.onBattery?(mouse, battery)
            }
        }
    }

    // MARK: - I/O

    private var primaryUsageIsMouse: Bool {
        (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) == kHIDUsage_GD_Mouse
    }

    private func property(_ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    /// `reply` gets the parameters, or nil on an error or no answer.
    private func send(_ deviceIndex: UInt8, _ featureIndex: UInt8, function: UInt8, params: [UInt8] = [],
                      reply: @escaping ([UInt8]?) -> Void) {
        queue.append(Pending(deviceIndex: deviceIndex, featureIndex: featureIndex, function: function,
                             params: params, reply: reply))
        sendNextIfIdle()
    }

    private func sendNextIfIdle() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        inFlight = request
        let report = HIDPP.request(deviceIndex: request.deviceIndex, featureIndex: request.featureIndex,
                                   function: request.function, params: request.params)
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPP.longReportID),
                                          report, report.count)
        guard result == kIOReturnSuccess else { return complete(with: nil) }

        generation += 1
        let sent = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == sent, self.inFlight != nil else { return }
            self.complete(with: nil)
        }
    }

    private func complete(with params: [UInt8]?) {
        guard let request = inFlight else { return }
        inFlight = nil
        request.reply(params)
        sendNextIfIdle()
    }

    private func received(_ report: [UInt8]) {
        switch HIDPP.parse(report) {
        case let .response(deviceIndex, featureIndex, function, params)?:
            guard let request = inFlight, request.deviceIndex == deviceIndex,
                  request.featureIndex == featureIndex, request.function == function else { return }
            complete(with: params)
        case let .error(deviceIndex, featureIndex, function)?:
            guard let request = inFlight, request.deviceIndex == deviceIndex,
                  request.featureIndex == featureIndex, request.function == function else { return }
            complete(with: nil)
        case let .event(deviceIndex, featureIndex, _, params)?:
            // The mouse announces battery changes (feature 0x1004) itself.
            guard let mouse = mice[deviceIndex], featureIndex == mouse.featureIndex[.unifiedBattery],
                  let battery = HIDPP.unifiedBattery(params) else { return }
            onBattery?(mouse, battery)
        case let .receiverConnection(deviceIndex)?:
            // A mouse behind a receiver woke up or was paired: (re)identify it.
            guard isReceiver, (1...6).contains(deviceIndex) else { return }
            notMice.remove(deviceIndex)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.identify(deviceIndex: deviceIndex)
            }
        case nil:
            break
        }
    }
}

/// A Logitech mouse found through HID++.
struct LogitechMouse {
    let deviceIndex: UInt8
    var product: String
    var featureIndex: [HIDPP.Feature: UInt8] = [:]
    var isPointingDevice = false
    var unitID: String?
    var serial: String?

    /// Stable across Macs and Easy-Switch channels, each of which gives the
    /// mouse a different Bluetooth address.
    var hasSerial = false

    /// The unit ID, which identification always reads. Keying on the serial
    /// number instead (1.15.0–1.15.4) split a mouse in two whenever that
    /// separate request failed.
    var key: String {
        "logi:unit-\(unitID ?? "\(product)-\(deviceIndex)")"
    }

    /// The key 1.15.0–1.15.4 used when the serial number was read.
    var legacyKey: String? { serial.map { "logi:\($0)" } }

    var displayName: String { MouseName.model(product) }
}
