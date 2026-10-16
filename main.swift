// mxctl: control a Logitech MX Master 3S (or a similar HID++ 2.0 mouse) connected over Bluetooth LE
// on macOS, without Logi Options+: DPI, battery, and what each button does.
//
// The mouse forgets its settings when it powers off and comes back at its defaults (1000 DPI), so the
// agent (`mxctl watch`, installed as a LaunchAgent) re-applies them whenever the mouse reconnects.
// The agent also performs the keyboard shortcuts and commands assigned to buttons.

import CoreGraphics
import Foundation

let usage = """
    usage: mxctl                          show battery, DPI, and buttons
           mxctl dpi [<dpi>]              print or set the DPI
           mxctl battery                  print the battery charge
           mxctl buttons                  list the buttons and what each does
           mxctl button <button> <action> set what a button does; <action> is one of:
               left|right|middle|back|forward|thumb|smartshift
                                          act as that button (done by the mouse itself)
               keys <combo>               send a shortcut such as ctrl+up (needs the agent)
               run '<command>'            run a shell command (needs the agent)
               default                    the button's own function
           mxctl watch                    stay running: re-apply settings when the mouse
                                          reconnects, and perform keys and run actions
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

/// One line per configurable button: its name and what it does now.
func describeButtons(_ mouse: Mouse, _ settings: Settings) throws -> [String] {
    try mouse.controls().filter(\.isConfigurable).map { control in
        let now = try mouse.reporting(control)
        let current = now.actingAs == control.cid ? "default" : "acts as \(controlName(now.actingAs))"
        let does: String
        switch (now.diverted, settings.buttons[control.name]) {
        case (true, let saved?) where saved.needsAgent:
            does = saved.description
        case (true, _):
            does = "sent to mxctl, but no action is saved"
        case (false, let saved?) where saved.needsAgent:
            does = "\(current) (\(saved) is saved but not applied; is the agent running?)"
        default:
            does = current
        }
        return control.name.padding(toLength: 12, withPad: " ", startingAt: 0) + does
    }
}

func showStatus() throws {
    let settings = try Settings.load()
    for mouse in try connectedMice() {
        let dpi = try mouse.dpi()
        let range = try mouse.dpiRange()
        print(mouse.name)
        if try mouse.featureIndex(featureBattery) != nil {
            let battery = try mouse.battery()
            print("  battery   \(battery)")
        }
        print("  dpi       \(dpi.current) (default \(dpi.standard), supports \(range))")
        if try mouse.featureIndex(featureControls) != nil {
            print("  buttons")
            for line in try describeButtons(mouse, settings) { print("    \(line)") }
        }
    }
    print("settings    \(settingsURL.path)")
    print("agent       \(agentIsLoaded() ? "installed" : "not installed") (\(agentLabel))")
}

func showButtons() throws {
    let settings = try Settings.load()
    let mice = try connectedMice()
    for mouse in mice {
        if mice.count > 1 { print(mouse.name) }
        for line in try describeButtons(mouse, settings) { print(line) }
        var functions: [String] = []
        for control in try mouse.controls() where control.isConfigurable {
            for target in try mouse.targets(for: control) where !functions.contains(target.name) {
                functions.append(target.name)
            }
        }
        print("a button can act as \(functions.joined(separator: ", ")), send keys, or run a command (see mxctl help)")
    }
}

func setButton(_ name: String, _ words: [String]) throws {
    let action: ButtonAction?  // nil means the button's own function
    switch (words[0], words.count) {
    case ("default", 1):
        action = nil
    case ("keys", 2):
        _ = try KeyCombo(words[1])
        action = ButtonAction(keys: words[1])
    case ("run", 2):
        action = ButtonAction(run: words[1])
    case ("run", _):
        throw MXError("put the command in quotes: mxctl button \(name) run '<command>'")
    case (let function, 1) where function != "keys":
        action = ButtonAction(remap: function)
    default:
        usageError()
    }
    var settings = try Settings.load()
    for mouse in try connectedMice() {
        let controls = try mouse.controls().filter(\.isConfigurable)
        guard let control = controls.first(where: { $0.name == name }) else {
            throw MXError("\(mouse.name) has no button '\(name)'; its buttons: \(controls.map(\.name).joined(separator: ", "))")
        }
        if let action, action.needsAgent {
            // The agent diverts the button and performs the action.
            guard control.divertable else { throw MXError("\(name) cannot send its presses to mxctl") }
            continue
        }
        let targets = try mouse.targets(for: control)
        guard let target = targets.first(where: { $0.name == (action?.remap ?? name) }) else {
            throw MXError("\(name) can act as: \(targets.map(\.name).joined(separator: ", "))")
        }
        try mouse.setReporting(control, diverted: false, actingAs: target.cid)
    }
    settings.buttons[name] = action
    try settings.save()
    print("\(name): \(action?.description ?? "default")")
    guard let action, action.needsAgent else { return }
    if action.keys != nil, !CGPreflightPostEventAccess() {
        _ = CGRequestPostEventAccess()
        print("to send shortcuts, turn on mxctl in System Settings > Privacy & Security > Accessibility")
    }
    if !agentIsLoaded() { print("the agent performs this action; start it with `mxctl install`") }
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
    case "buttons" where arguments.count == 1:
        try showButtons()
    case "button" where arguments.count >= 3:
        try setButton(arguments[1], Array(arguments[2...]))
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
