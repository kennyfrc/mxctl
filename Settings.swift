import Foundation
import notify

let home = FileManager.default.homeDirectoryForCurrentUser
let settingsURL = home.appendingPathComponent(".config/mxctl/settings.json")
/// Posted after the settings file changes, so a running agent applies it right away.
let settingsChangedNotification = "local.mxctl.settings-changed"

/// Everything the agent keeps applied, stored in ~/.config/mxctl/settings.json.
struct Settings: Codable {
    var dpi: Int?

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
