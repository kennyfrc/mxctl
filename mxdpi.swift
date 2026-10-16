// mxdpi: read and set the DPI of a Logitech MX Master 3S (or another HID++ 2.0 mouse)
// connected over Bluetooth LE on macOS, without Logi Options+.
//
// Over Bluetooth the mouse exposes HID++ as vendor collection 0xFF43/0x0202 with long reports only:
// report 0x11, 20 bytes = [0x11, device 0xFF, feature index, function << 4 | software id, 16 params].
// DPI lives in feature 0x2201 (Adjustable DPI). The mouse forgets it when it powers off and comes
// back at its default (1000), so `watch` re-applies the saved value whenever the mouse reconnects.

import Foundation
import IOKit.hid

let logitechVendorID = 0x046D
let hidppUsagePage = 0xFF43
let reportID: UInt8 = 0x11
let reportLength = 20
let featureAdjustableDPI: UInt16 = 0x2201
let featureWirelessStatus: UInt16 = 0x1D4B  // the mouse sends an event from this feature after it reconnects
let matching = [kIOHIDVendorIDKey: logitechVendorID, kIOHIDDeviceUsagePageKey: hidppUsagePage] as CFDictionary

let home = FileManager.default.homeDirectoryForCurrentUser
let savedDPIURL = home.appendingPathComponent(".config/mxdpi/dpi")
let agentLabel = "local.mxdpi"
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logURL = home.appendingPathComponent("Library/Logs/mxdpi.log")

let hidppErrors = ["no error", "unknown", "invalid argument", "out of range", "hardware error",
                   "internal error", "invalid feature index", "invalid function", "busy", "unsupported"]

let usage = """
    usage: mxdpi [get]        print the current DPI
           mxdpi set <dpi>    set the DPI and save it for `watch`
           mxdpi info         show the supported range, the default, and the saved DPI
           mxdpi watch        stay running; re-apply the saved DPI whenever the mouse reconnects
           mxdpi install      run `mxdpi watch` at login (LaunchAgent \(agentLabel))
           mxdpi uninstall    remove the LaunchAgent
    """

struct MXError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// macOS lets a process open a Bluetooth mouse only with Input Monitoring permission.
struct PermissionError: Error, CustomStringConvertible {
    var description: String {
        "macOS blocked access to the mouse. Turn on mxdpi in System Settings > Privacy & Security > "
            + "Input Monitoring (or add \(Bundle.main.executablePath ?? "mxdpi") there with +), then try again."
    }
}

let ioReturnNotPermitted = IOReturn(bitPattern: 0xE000_02E2)

func describe(_ status: IOReturn) -> String {
    String(cString: mach_error_string(status))
}

let timestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func logLine(_ message: String) {
    print("\(timestamp.string(from: Date())) \(message)")
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
            // Asking once adds mxdpi to the Input Monitoring list and shows the system prompt.
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

    private func dpiFeature() throws -> UInt8 {
        guard let index = try featureIndex(featureAdjustableDPI) else {
            throw MXError("\(name) has no adjustable DPI (HID++ feature 0x2201)")
        }
        return index
    }

    func dpiRange() throws -> DPIRange {
        let params = try request(dpiFeature(), 0x1, [0])
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
        let params = try request(dpiFeature(), 0x2, [0])
        return (Int(params[1]) << 8 | Int(params[2]), Int(params[3]) << 8 | Int(params[4]))
    }

    func setDPI(_ dpi: Int) throws -> Int {
        let params = try request(dpiFeature(), 0x3, [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
        return Int(params[1]) << 8 | Int(params[2])
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
            if try mouse.featureIndex(featureAdjustableDPI) != nil { mice.append(mouse) }
        } catch {
            firstError = firstError ?? error
        }
    }
    guard !mice.isEmpty else {
        throw firstError ?? MXError("no Logitech mouse found; is it on and connected over Bluetooth?")
    }
    return mice
}

func savedDPI() -> Int? {
    guard let text = try? String(contentsOf: savedDPIURL, encoding: .utf8) else { return nil }
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func saveDPI(_ dpi: Int) throws {
    try FileManager.default.createDirectory(at: savedDPIURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "\(dpi)\n".write(to: savedDPIURL, atomically: true, encoding: .utf8)
}

/// Keeps the saved DPI applied: at start, whenever a mouse connects, and when it reports a reconnect.
final class Watcher {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var mice: [IOHIDDevice: Mouse] = [:]

    func run() -> Never {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, matching)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<Watcher>.fromOpaque(context!).takeUnretainedValue().connected(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<Watcher>.fromOpaque(context!).takeUnretainedValue().disconnected(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        logLine("watching; saved DPI: \(savedDPI().map(String.init) ?? "none")")
        withExtendedLifetime(self) { CFRunLoopRun() }
        exit(0)
    }

    private func connected(_ device: IOHIDDevice) {
        // Give a device that just appeared a moment before talking HID++ to it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            do {
                let mouse = try Mouse(device, softwareID: 0x0C)
                guard try mouse.featureIndex(featureAdjustableDPI) != nil else { return }
                let wirelessStatus = try mouse.featureIndex(featureWirelessStatus)
                mouse.onEvent = { [weak mouse] featureIndex, params in
                    guard let mouse, featureIndex == wirelessStatus else { return }
                    logLine("\(mouse.name) sent a reconnect event (\(params.prefix(3).map(String.init).joined(separator: " ")))")
                    DispatchQueue.main.async { [weak mouse] in
                        if let mouse { self.apply(mouse) }
                    }
                }
                mice[device] = mouse
                logLine("\(mouse.name) connected")
                apply(mouse)
            } catch let error as PermissionError {
                logLine("\(error)")
                // A new grant may apply only to a new process; exit and let launchd start a fresh one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(1) }
            } catch {
                logLine("\(error)")
            }
        }
    }

    private func disconnected(_ device: IOHIDDevice) {
        if let mouse = mice.removeValue(forKey: device) { logLine("\(mouse.name) disconnected") }
    }

    private func apply(_ mouse: Mouse, attempt: Int = 1) {
        guard let wanted = savedDPI() else {
            logLine("\(mouse.name): no saved DPI yet; run `mxdpi set <dpi>`")
            return
        }
        do {
            let found = try mouse.dpi().current
            if found == wanted {
                logLine("\(mouse.name) is at \(wanted) DPI")
            } else {
                let now = try mouse.setDPI(wanted)
                logLine("\(mouse.name) was at \(found) DPI, set to \(now)")
            }
        } catch {
            logLine("\(mouse.name): \(error)")
            guard attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak mouse] in
                if let mouse, self.mice.values.contains(where: { $0 === mouse }) { self.apply(mouse, attempt: attempt + 1) }
            }
        }
    }
}

func setDPI(_ wanted: Int) throws {
    var applied: Int?
    for mouse in try connectedMice() {
        let range = try mouse.dpiRange()
        guard let lowest = range.values.first, let highest = range.values.last, lowest <= wanted, wanted <= highest,
              let target = range.closest(to: wanted) else {
            throw MXError("\(wanted) DPI is outside the range of \(mouse.name): \(range)")
        }
        let before = try mouse.dpi().current
        let after = try mouse.setDPI(target)
        print("\(mouse.name): \(before) -> \(after) DPI" + (target == wanted ? "" : " (nearest step to \(wanted))"))
        applied = after
    }
    if let applied { try saveDPI(applied) }
}

func showInfo() throws {
    for mouse in try connectedMice() {
        let dpi = try mouse.dpi()
        let range = try mouse.dpiRange()
        print(mouse.name)
        print("  current:   \(dpi.current) DPI")
        print("  default:   \(dpi.standard) DPI")
        print("  supported: \(range)")
    }
    let agent = FileManager.default.fileExists(atPath: agentURL.path) ? "installed" : "not installed"
    print("saved DPI:   \(savedDPI().map(String.init) ?? "none") (\(savedDPIURL.path))")
    print("agent:       \(agent) (\(agentURL.path))")
}

@discardableResult
func launchctl(_ arguments: String..., quiet: Bool = false) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    if quiet { process.standardError = FileHandle.nullDevice }
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

func installAgent() throws {
    guard savedDPI() != nil else { throw MXError("run `mxdpi set <dpi>` first; the agent re-applies the saved DPI") }
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        throw MXError("cannot find the path of this program")
    }
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [executable.path, "watch"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
    ]
    try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL)
    let domain = "gui/\(getuid())"
    launchctl("bootout", "\(domain)/\(agentLabel)", quiet: true)
    // bootstrap can fail for a moment while launchd finishes removing the old copy.
    for attempt in 1...5 {
        if launchctl("bootstrap", domain, agentURL.path, quiet: attempt < 5) == 0 {
            print("installed \(agentLabel): runs `\(executable.path) watch` at login; log: \(logURL.path)")
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    throw MXError("launchctl could not load \(agentURL.path)")
}

func uninstallAgent() {
    launchctl("bootout", "gui/\(getuid())/\(agentLabel)", quiet: true)
    try? FileManager.default.removeItem(at: agentURL)
    print("removed \(agentLabel)")
}

/// macOS checks Input Monitoring against the app that started a program, such as the terminal.
/// Starting again as our own responsible process means only mxdpi needs the permission, so the
/// CLI and the LaunchAgent share one grant. launchd already starts its jobs this way.
func relaunchAsOwnResponsibleProcess() {
    guard getenv("MXDPI_RELAUNCHED") == nil, getppid() != 1, let path = Bundle.main.executablePath,
          let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else { return }
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1) == 0 else { return }
    setenv("MXDPI_RELAUNCHED", "1", 1)
    let argv = CommandLine.arguments.map { strdup($0) } + [nil]
    var pid: pid_t = 0
    guard posix_spawn(&pid, path, nil, &attributes, argv, environ) == 0 else { return }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1, errno == EINTR {}
    exit(status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F))
}

func usageError() -> Never {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
if ["get", "set", "info", "watch"].contains(arguments.first ?? "get") {
    relaunchAsOwnResponsibleProcess()
}
do {
    switch arguments.first ?? "get" {
    case "get" where arguments.count <= 1:
        let mice = try connectedMice()
        for mouse in mice {
            let dpi = try mouse.dpi().current
            print(mice.count == 1 ? "\(dpi)" : "\(mouse.name): \(dpi)")
        }
    case "set" where arguments.count == 2:
        guard let dpi = Int(arguments[1]) else { usageError() }
        try setDPI(dpi)
    case "info" where arguments.count == 1:
        try showInfo()
    case "watch" where arguments.count == 1:
        Watcher().run()
    case "install" where arguments.count == 1:
        try installAgent()
    case "uninstall" where arguments.count == 1:
        uninstallAgent()
    case "help", "-h", "--help":
        print(usage)
    default:
        usageError()
    }
} catch {
    FileHandle.standardError.write(Data("mxdpi: \(error)\n".utf8))
    exit(1)
}
