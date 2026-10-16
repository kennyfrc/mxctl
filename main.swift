// mxctl: control a Logitech MX Master 3S (or a similar HID++ 2.0 mouse) connected over Bluetooth LE
// on macOS, without Logi Options+: DPI and battery.
//
// The mouse forgets its settings when it powers off and comes back at its defaults (1000 DPI), so the
// agent (`mxctl watch`, installed as a LaunchAgent) re-applies them whenever the mouse reconnects.

import Foundation

let usage = """
    usage: mxctl                          show battery, DPI, and the agent
           mxctl dpi [<dpi>]              print or set the DPI
           mxctl battery                  print the battery charge
           mxctl watch                    stay running: re-apply settings when the mouse
                                          reconnects
           mxctl install | uninstall      run `mxctl watch` at login (LaunchAgent \(agentLabel))
    """

/// macOS checks Input Monitoring against the app that started a program, such as the terminal.
/// Starting again as our own responsible process means only mxctl needs the permission, so the
/// CLI and the LaunchAgent share one grant. launchd already starts its jobs this way.
func relaunchAsOwnResponsibleProcess() {
    guard getenv("MXCTL_RELAUNCHED") == nil, getppid() != 1, let path = Bundle.main.executablePath,
          let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim") else { return }
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1) == 0 else { return }
    setenv("MXCTL_RELAUNCHED", "1", 1)
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

/// Prints one value per connected mouse, with the mouse's name when there is more than one.
func printEachMouse(_ value: (Mouse) throws -> String) throws {
    let mice = try connectedMice()
    for mouse in mice {
        let text = try value(mouse)
        print(mice.count == 1 ? text : "\(mouse.name): \(text)")
    }
}

func setDPI(_ wanted: Int) throws {
    var settings = try Settings.load()
    for mouse in try connectedMice() {
        let range = try mouse.dpiRange()
        guard let lowest = range.values.first, let highest = range.values.last, lowest <= wanted, wanted <= highest,
              let target = range.closest(to: wanted) else {
            throw MXError("\(wanted) DPI is outside the range of \(mouse.name): \(range)")
        }
        let before = try mouse.dpi().current
        let after = try mouse.setDPI(target)
        print("\(mouse.name): \(before) -> \(after) DPI" + (target == wanted ? "" : " (nearest step to \(wanted))"))
        settings.dpi = after
    }
    try settings.save()
}

func showStatus() throws {
    for mouse in try connectedMice() {
        let dpi = try mouse.dpi()
        let range = try mouse.dpiRange()
        print(mouse.name)
        if try mouse.featureIndex(featureBattery) != nil {
            let battery = try mouse.battery()
            print("  battery   \(battery)")
        }
        print("  dpi       \(dpi.current) (default \(dpi.standard), supports \(range))")
    }
    print("settings    \(settingsURL.path)")
    print("agent       \(agentIsLoaded() ? "installed" : "not installed") (\(agentLabel))")
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "status"
if !["install", "uninstall", "help", "-h", "--help"].contains(command) {
    relaunchAsOwnResponsibleProcess()
}
do {
    switch command {
    case "status" where arguments.count <= 1:
        try showStatus()
    case "dpi" where arguments.count == 1:
        try printEachMouse { String(try $0.dpi().current) }
    case "dpi" where arguments.count == 2:
        guard let dpi = Int(arguments[1]) else { usageError() }
        try setDPI(dpi)
    case "battery" where arguments.count == 1:
        try printEachMouse { try $0.battery() }
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
    FileHandle.standardError.write(Data("mxctl: \(error)\n".utf8))
    exit(1)
}
