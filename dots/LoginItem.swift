import Foundation

// Launch at Login as a hand-written LaunchAgent plist rather than
// SMAppService, which would link ServiceManagement (~1MB at runtime)
// only to write the same file. Enabled once on first launch.
@MainActor
enum LoginItem {
    private static let autoEnabledKey = "loginItemAutoEnabled"

    private static var plistURL: URL {
        let label = Bundle.main.bundleIdentifier ?? "almazko.dots"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func toggle() {
        isEnabled ? disable() : enable()
    }

    static func ensureFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: autoEnabledKey) else { return }
        defaults.set(true, forKey: autoEnabledKey)
        enable()
    }

    private static func enable() {
        guard let exec = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": Bundle.main.bundleIdentifier ?? "almazko.dots",
            "ProgramArguments": [exec],
            "RunAtLoad": true,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: plistURL)
    }

    private static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
