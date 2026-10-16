// HID++ 2.0 over the vendor HID collection that Logitech mice expose over Bluetooth LE:
// usage page 0xFF43 with long reports only (ID 0x11, 20 bytes):
// [0x11, device 0xFF, feature index, function << 4 | software id, 16 params].

import Foundation
import IOKit.hid

let logitechVendorID = 0x046D
let hidppUsagePage = 0xFF43
let reportID: UInt8 = 0x11
let reportLength = 20
let featureBattery: UInt16 = 0x1004         // Unified Battery
let featureWirelessStatus: UInt16 = 0x1D4B  // the mouse sends an event from this feature after it reconnects
let featureDPI: UInt16 = 0x2201             // Adjustable DPI
let matching = [kIOHIDVendorIDKey: logitechVendorID, kIOHIDDeviceUsagePageKey: hidppUsagePage] as CFDictionary

let hidppErrors = ["no error", "unknown", "invalid argument", "out of range", "hardware error",
                   "internal error", "invalid feature index", "invalid function", "busy", "unsupported"]

struct MXError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// macOS lets a process open a Bluetooth mouse only with Input Monitoring permission.
struct PermissionError: Error, CustomStringConvertible {
    var description: String {
        "macOS blocked access to the mouse. Turn on mxctl in System Settings > Privacy & Security > "
            + "Input Monitoring (or add \(Bundle.main.executablePath ?? "mxctl") there with +), then try again."
    }
}

let ioReturnNotPermitted = IOReturn(bitPattern: 0xE000_02E2)

func describe(_ status: IOReturn) -> String {
    String(cString: mach_error_string(status))
}

/// Every DPI value a sensor accepts, in ascending order.
struct DPIRange: CustomStringConvertible {
    let values: [Int]
    let step: Int?

    var description: String {
        if let step, let first = values.first, let last = values.last {
            return "\(first)-\(last) in steps of \(step)"
        }
        return values.map(String.init).joined(separator: ", ")
    }

    func closest(to dpi: Int) -> Int? {
        values.min { abs($0 - dpi) < abs($1 - dpi) }
    }
}

/// A Logitech device that speaks HID++ 2.0 through its vendor HID collection.
final class Mouse {
    let device: IOHIDDevice
    let name: String
    private let softwareID: UInt8
    private let buffer: UnsafeMutablePointer<UInt8>
    private var pending: (featureIndex: UInt8, function: UInt8)?
    private var reply: Result<[UInt8], MXError>?
    private var featureIndexes: [UInt16: UInt8] = [:]
    /// Called for reports the mouse sends on its own (software id 0), such as the reconnect event.
    var onEvent: ((_ featureIndex: UInt8, _ params: [UInt8]) -> Void)?

    init(_ device: IOHIDDevice, softwareID: UInt8) throws {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Logitech device"
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if status == ioReturnNotPermitted {
            // Asking once adds mxctl to the Input Monitoring list and shows the system prompt.
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            }
            throw PermissionError()
        }
        guard status == kIOReturnSuccess else { throw MXError("cannot open \(name): \(describe(status))") }
        self.device = device
        self.name = name
        self.softwareID = softwareID
        buffer = .allocate(capacity: 64)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            let mouse = Unmanaged<Mouse>.fromOpaque(context!).takeUnretainedValue()
            mouse.received(Array(UnsafeBufferPointer(start: report, count: length)))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    /// Sends one HID++ request and waits up to two seconds for the matching reply.
    func request(_ featureIndex: UInt8, _ function: UInt8, _ params: [UInt8] = []) throws -> [UInt8] {
        var report = [UInt8](repeating: 0, count: reportLength)
        report[0] = reportID
        report[1] = 0xFF  // device index of a mouse paired directly over Bluetooth
        report[2] = featureIndex
        report[3] = function << 4 | softwareID
        report.replaceSubrange(4..<4 + params.count, with: params)
        pending = (featureIndex, report[3])
        reply = nil
        defer { pending = nil }
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), report, report.count)
        guard status == kIOReturnSuccess else { throw MXError("cannot write to \(name): \(describe(status))") }
        let deadline = Date(timeIntervalSinceNow: 2)
        while reply == nil, Date() < deadline {
            _ = CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        guard let reply else { throw MXError("\(name) did not answer") }
        return try reply.get()
    }

    private func received(_ report: [UInt8]) {
        guard report.count >= 7, report[0] == reportID else { return }
        if let pending, report[2] == pending.featureIndex, report[3] == pending.function {
            reply = .success(Array(report[4...]))
        } else if let pending, report[2] == 0xFF, report[3] == pending.featureIndex, report[4] == pending.function {
            let code = Int(report[5])
            reply = .failure(MXError("\(name) rejected the request: \(code < hidppErrors.count ? hidppErrors[code] : "error \(code)")"))
        } else if report[3] & 0x0F == 0 {
            onEvent?(report[2], Array(report[4...]))
        }
    }

    /// Looks up where the mouse keeps a feature; nil if it does not have it.
    func featureIndex(_ feature: UInt16) throws -> UInt8? {
        if let index = featureIndexes[feature] { return index }
        let index = try request(0x00, 0x0, [UInt8(feature >> 8), UInt8(feature & 0xFF)])[0]
        guard index != 0 else { return nil }
        featureIndexes[feature] = index
        return index
    }

    func requireFeature(_ feature: UInt16, _ purpose: String) throws -> UInt8 {
        guard let index = try featureIndex(feature) else {
            throw MXError("\(name) has no \(purpose) (HID++ feature \(String(format: "0x%04X", feature)))")
        }
        return index
    }

    // MARK: DPI (0x2201)

    func dpiRange() throws -> DPIRange {
        let params = try request(requireFeature(featureDPI, "adjustable DPI"), 0x1, [0])
        var values: [Int] = []
        var step: Int?
        for i in stride(from: 1, to: params.count - 1, by: 2) {
            let value = Int(params[i]) << 8 | Int(params[i + 1])
            if value == 0 { break }
            // A value with the top three bits set is the step between the values around it.
            if value >> 13 == 0b111 { step = value & 0x1FFF } else { values.append(value) }
        }
        if let step, values.count == 2 {
            return DPIRange(values: Array(stride(from: values[0], through: values[1], by: step)), step: step)
        }
        return DPIRange(values: values, step: nil)
    }

    func dpi() throws -> (current: Int, standard: Int) {
        let params = try request(requireFeature(featureDPI, "adjustable DPI"), 0x2, [0])
        return (Int(params[1]) << 8 | Int(params[2]), Int(params[3]) << 8 | Int(params[4]))
    }

    func setDPI(_ dpi: Int) throws -> Int {
        let params = try request(requireFeature(featureDPI, "adjustable DPI"), 0x3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
        return Int(params[1]) << 8 | Int(params[2])
    }

    // MARK: Battery (0x1004)

    /// Charge and charging state, such as "85%, discharging".
    func battery() throws -> String {
        let index = try requireFeature(featureBattery, "battery reporting")
        let capabilities = try request(index, 0x0)
        let status = try request(index, 0x1)
        let levels: [UInt8: String] = [8: "full", 4: "good", 2: "low", 1: "critical"]
        let charge = capabilities[1] & 0x02 != 0 ? "\(status[0])%" : levels[status[1]] ?? "unknown level"
        let states = ["discharging", "charging", "charging slowly", "fully charged", "charging error"]
        return "\(charge), " + (Int(status[2]) < states.count ? states[Int(status[2])] : "charging state \(status[2])")
    }
}

/// Opens every connected Logitech HID++ device that has adjustable DPI.
func connectedMice() throws -> [Mouse] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, matching)
    let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    var mice: [Mouse] = []
    var firstError: Error?
    for device in devices {
        do {
            let mouse = try Mouse(device, softwareID: 0x0B)
            if try mouse.featureIndex(featureDPI) != nil { mice.append(mouse) }
        } catch {
            firstError = firstError ?? error
        }
    }
    guard !mice.isEmpty else {
        throw firstError ?? MXError("no Logitech mouse found; is it on and connected over Bluetooth?")
    }
    return mice
}
