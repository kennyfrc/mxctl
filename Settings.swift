import Foundation
import notify

let home = FileManager.default.homeDirectoryForCurrentUser
let settingsURL = home.appendingPathComponent(".config/mxctl/settings.json")
/// Posted after the settings file changes, so a running agent applies it right away.
let settingsChangedNotification = "local.mxctl.settings-changed"

/// What one button does. Exactly one field is set.
struct ButtonAction: Codable, Equatable, CustomStringConvertible {
    /// Another button's function, performed by the mouse itself.
    var remap: String?
    /// A keyboard shortcut such as "ctrl+up", sent by the agent.
    var keys: String?
    /// A shell command, run by the agent.
    var run: String?

    /// Shortcuts and commands need the agent to see the press.
    var needsAgent: Bool { keys != nil || run != nil }

    var description: String {
        if let keys { return "keys \(keys)" }
        if let run { return "run \(run)" }
        return "acts as \(remap ?? "itself")"
    }
}

/// Everything the agent keeps applied, stored in ~/.config/mxctl/settings.json.
struct Settings: Codable {
    var dpi: Int?
    var buttons: [String: ButtonAction] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dpi = try container.decodeIfPresent(Int.self, forKey: .dpi)
        buttons = try container.decodeIfPresent([String: ButtonAction].self, forKey: .buttons) ?? [:]
    }

    static func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
        } catch {
            throw MXError("cannot read \(settingsURL.path): \(error.localizedDescription)")
        }
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: settingsURL, options: .atomic)
        notify_post(settingsChangedNotification)
    }
}
