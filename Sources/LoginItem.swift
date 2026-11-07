import Foundation
import ServiceManagement

/// "Open at login" without Apple's paid signing: a per-user LaunchAgent, the same one install.sh writes.
/// It is only written, not loaded, so it takes effect at the next login and never starts a second copy now.
enum LoginItem {
    static let label = AppInfo.bundleID
    static var plistURL: URL { Paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The plist is there, but the person switched it off under Login Items in System Settings.
    static var blockedInSettings: Bool {
        SMAppService.statusForLegacyPlist(at: plistURL) == .requiresApproval
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// macOS runs a freshly downloaded app from a temporary read-only copy until it's moved
    /// out of Downloads; a login item pointing there would break.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static var inApplicationsFolder: Bool { Bundle.main.bundlePath.contains("/Applications/") }

    static func plist(executable: String) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable, "--menubar"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
    }

    static func enable() throws {
        guard let exe = Bundle.main.executablePath else {
            throw NSError(domain: AppInfo.bundleID, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't find the app's own location."])
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: exe), format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    static func disable() throws {
        if isEnabled { try FileManager.default.removeItem(at: plistURL) }
    }

    /// The login item starts a different copy of the app (for example, after the app was moved).
    static var pointsElsewhere: Bool {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let first = (dict["ProgramArguments"] as? [String])?.first,
              let exe = Bundle.main.executablePath else { return false }
        return URL(fileURLWithPath: first).standardizedFileURL.path != URL(fileURLWithPath: exe).standardizedFileURL.path
    }
}
