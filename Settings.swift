import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let savedDPIURL = home.appendingPathComponent(".config/mxctl/dpi")

func savedDPI() -> Int? {
    guard let text = try? String(contentsOf: savedDPIURL, encoding: .utf8) else { return nil }
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func saveDPI(_ dpi: Int) throws {
    try FileManager.default.createDirectory(at: savedDPIURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "\(dpi)\n".write(to: savedDPIURL, atomically: true, encoding: .utf8)
}
