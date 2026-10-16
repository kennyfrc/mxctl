import Foundation
import IOKit.hid

let agentLabel = "local.mxctl"
let agentURL = home.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
let logURL = home.appendingPathComponent("Library/Logs/mxctl.log")

let timestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

func logLine(_ message: String) {
    print("\(timestamp.string(from: Date())) \(message)")
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
            logLine("\(mouse.name): no saved DPI yet; run `mxctl set <dpi>`")
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
    guard savedDPI() != nil else { throw MXError("run `mxctl set <dpi>` first; the agent re-applies the saved DPI") }
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
