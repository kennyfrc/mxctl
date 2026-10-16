import Carbon.HIToolbox
import CoreGraphics

/// A keyboard shortcut such as "ctrl+up" or "cmd+shift+4", posted as if typed on the keyboard.
struct KeyCombo {
    let key: CGKeyCode
    let flags: CGEventFlags

    init(_ text: String) throws {
        var flags: CGEventFlags = []
        var key: (code: Int, flags: CGEventFlags)?
        for part in text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init) {
            if let modifier = modifierFlags[part] {
                flags.insert(modifier)
                continue
            }
            guard let found = keyCodes[part] else { throw MXError("unknown key '\(part)' in '\(text)'") }
            guard key == nil else { throw MXError("'\(text)' has more than one key") }
            key = found
        }
        guard let key else { throw MXError("'\(text)' has no key besides modifiers") }
        self.key = CGKeyCode(key.code)
        self.flags = flags.union(key.flags)
    }

    func post() {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

private let modifierFlags: [String: CGEventFlags] = [
    "cmd": .maskCommand, "command": .maskCommand,
    "ctrl": .maskControl, "control": .maskControl,
    "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate,
    "shift": .maskShift, "fn": .maskSecondaryFn,
]

/// Key codes by US-layout position. A real keyboard sends arrows with the numeric-pad and fn flags,
/// and function and navigation keys with fn; some system shortcuts only match with them.
private let keyCodes: [String: (code: Int, flags: CGEventFlags)] = {
    var codes: [String: (code: Int, flags: CGEventFlags)] = [:]
    let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
                   kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
                   kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
                   kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z]
    for (letter, code) in zip("abcdefghijklmnopqrstuvwxyz", letters) { codes[String(letter)] = (code, []) }
    let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                  kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    for (digit, code) in digits.enumerated() { codes[String(digit)] = (code, []) }
    let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = (code, .maskSecondaryFn) }
    let plain = [
        "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "delete": kVK_Delete,
        "escape": kVK_Escape, "esc": kVK_Escape, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash,
        "`": kVK_ANSI_Grave,
    ]
    for (name, code) in plain { codes[name] = (code, []) }
    let navigation = ["home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
                      "forwarddelete": kVK_ForwardDelete]
    for (name, code) in navigation { codes[name] = (code, .maskSecondaryFn) }
    let arrows = ["left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow]
    for (name, code) in arrows { codes[name] = (code, [.maskNumericPad, .maskSecondaryFn]) }
    return codes
}()
