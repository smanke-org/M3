import Foundation

/// Logitech's HID++ 2.0 protocol, just enough to identify a mouse and read its
/// battery. Pure encoding and decoding; `LogitechEndpoint` does the I/O.
///
/// A long report is 20 bytes: report ID 0x11, device index, feature index,
/// function (high nibble) | software ID (low nibble), then 16 parameter bytes.
/// Bluetooth mice answer on device index 0xFF; mice behind a Bolt or Unifying
/// receiver answer on their pairing slot, 1–6.
enum HIDPP {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    /// Tags our requests. Logi Options+ uses its own, so replies to its
    /// requests (which every opener of the device also receives) are ignored.
    static let softwareID: UInt8 = 0x0B
    static let bluetoothDeviceIndex: UInt8 = 0xFF

    enum Feature: UInt16 {
        case root = 0x0000
        case deviceInformation = 0x0003
        case deviceNameType = 0x0005
        case batteryStatus = 0x1000
        case unifiedBattery = 0x1004
    }

    /// From feature 0x0005 `getDeviceType`.
    enum DeviceType: UInt8 {
        case keyboard = 0, remoteControl, numpad, mouse, trackpad, trackball, presenter, receiver

        var isPointingDevice: Bool { self == .mouse || self == .trackball }
    }

    static func request(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8] = []) -> [UInt8] {
        var report: [UInt8] = [longReportID, deviceIndex, featureIndex, (function << 4) | softwareID]
        report += params.prefix(longReportLength - report.count)
        report += Array(repeating: 0, count: longReportLength - report.count)
        return report
    }

    enum Message: Equatable {
        /// A reply to one of our requests.
        case response(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8])
        /// Something the device sent on its own, such as a battery change.
        case event(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8, params: [UInt8])
        /// Our request failed: an unknown feature, or a device that's asleep.
        case error(deviceIndex: UInt8, featureIndex: UInt8, function: UInt8)
        /// A receiver reporting that a paired device connected or disconnected.
        case receiverConnection(deviceIndex: UInt8)
    }

    /// Nil for anything that isn't HID++, like the mouse's ordinary motion
    /// reports, or that answers another app's request.
    static func parse(_ report: [UInt8]) -> Message? {
        guard report.count >= 7, report[0] == shortReportID || report[0] == longReportID else { return nil }
        let deviceIndex = report[1]
        switch report[2] {
        case 0xFF, 0x8F:
            // HID++ 2.0 and 1.0 error replies: the failed request's feature
            // index and function|software ID follow.
            guard report[4] & 0x0F == softwareID else { return nil }
            return .error(deviceIndex: deviceIndex, featureIndex: report[3], function: report[4] >> 4)
        case 0x41 where report[0] == shortReportID:
            return .receiverConnection(deviceIndex: deviceIndex)
        default:
            let params = Array(report[4...])
            let software = report[3] & 0x0F
            let function = report[3] >> 4
            if software == softwareID {
                return .response(deviceIndex: deviceIndex, featureIndex: report[2], function: function, params: params)
            }
            if software == 0 {
                return .event(deviceIndex: deviceIndex, featureIndex: report[2], function: function, params: params)
            }
            return nil
        }
    }

    struct Battery: Equatable {
        var percent: Int
        /// Plugged in, whether still charging or full.
        var isCharging: Bool
        /// The mouse's own "critical" flag. Some mice report their level in
        /// coarse steps, so this can come before the percentage looks low.
        var isCritical = false
    }

    /// Feature 0x1004 `getStatus` (function 1), and its battery events.
    /// params[0] is the charge in percent; params[2] is 0 discharging,
    /// 1–2 charging, 3 charged, 4 error.
    static func unifiedBattery(_ params: [UInt8]) -> Battery? {
        guard params.count >= 3, params[0] <= 100 else { return nil }
        // params[1] is the level as flags: 1 critical, 2 low, 4 good, 8 full.
        return Battery(percent: Int(params[0]), isCharging: (1...3).contains(params[2]),
                       isCritical: params[1] & 0x01 != 0)
    }

    /// Feature 0x1000 `getBatteryLevelStatus` (function 0), for older mice.
    /// params[2] is 0 discharging, 1 recharging, 2 almost full, 3 full, 4 slow recharge.
    static func batteryStatus(_ params: [UInt8]) -> Battery? {
        guard params.count >= 3, params[0] <= 100, params[0] > 0 else { return nil }
        return Battery(percent: Int(params[0]), isCharging: (1...4).contains(params[2]))
    }

    /// Feature 0x0003 `getDeviceInfo` (function 0): the 4-byte unit ID, and
    /// whether the device can report a serial number.
    static func deviceInfo(_ params: [UInt8]) -> (unitID: String, hasSerial: Bool)? {
        guard params.count >= 15 else { return nil }
        let unitID = params[1...4].map { String(format: "%02x", $0) }.joined()
        return (unitID, params[14] & 0x01 == 1)
    }

    /// Feature 0x0003 `getSerialNumber` (function 2): 12 ASCII characters.
    static func serialNumber(_ params: [UInt8]) -> String? {
        let bytes = params.prefix(12).prefix { $0 != 0 }
        guard bytes.count >= 4, bytes.allSatisfy({ (0x21...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }
}
