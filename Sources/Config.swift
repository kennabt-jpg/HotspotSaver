import Foundation

enum ControlKind: String, Codable {
    /// A regular app: paused by quitting it, resumed by reopening it in the background.
    case app
    /// One or more launchd agents (usually auto-updaters): paused by unloading, resumed by reloading.
    case launchAgents
    /// Your own shell commands.
    case shell
}

enum SaverMode: String, Codable {
    case auto   // pause things automatically while tethered
    case on     // always behave as if tethered
    case off    // never pause anything automatically
}

struct Control: Codable {
    var id: String
    var name: String
    var group: String
    var kind: ControlKind
    /// Pause this automatically when a hotspot is detected.
    var autoPause: Bool
    // kind == app
    var bundleId: String?
    // kind == launchAgents ("*" wildcards allowed)
    var labels: [String]?
    /// Extra processes to stop when pausing (matched against the full command path).
    var processNames: [String]?
    // kind == shell
    var pauseCommand: String?
    var resumeCommand: String?
    /// Exit status 0 means "currently on".
    var statusCommand: String?
    var note: String?

    init(id: String, name: String, group: String, kind: ControlKind, autoPause: Bool,
         bundleId: String? = nil, labels: [String]? = nil, processNames: [String]? = nil,
         pauseCommand: String? = nil, resumeCommand: String? = nil, statusCommand: String? = nil,
         note: String? = nil) {
        self.id = id; self.name = name; self.group = group; self.kind = kind; self.autoPause = autoPause
        self.bundleId = bundleId; self.labels = labels; self.processNames = processNames
        self.pauseCommand = pauseCommand; self.resumeCommand = resumeCommand
        self.statusCommand = statusCommand; self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case id, name, group, kind, autoPause, bundleId, labels, processNames,
             pauseCommand, resumeCommand, statusCommand, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? "Other"
        kind = try c.decode(ControlKind.self, forKey: .kind)
        autoPause = try c.decodeIfPresent(Bool.self, forKey: .autoPause) ?? true
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        processNames = try c.decodeIfPresent([String].self, forKey: .processNames)
        pauseCommand = try c.decodeIfPresent(String.self, forKey: .pauseCommand)
        resumeCommand = try c.decodeIfPresent(String.self, forKey: .resumeCommand)
        statusCommand = try c.decodeIfPresent(String.self, forKey: .statusCommand)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}

struct DetectionConfig: Codable {
    /// Treat any connection macOS flags as metered ("expensive") as a hotspot.
    var useMeteredFlag = true
    /// Gateway/address prefixes that identify a phone hotspot. iPhones always use 172.20.10.x.
    var hotspotAddressPrefixes = ["172.20.10."]
    /// Wait this long for the network to settle before acting on a change.
    var settleSeconds = 4.0
    /// Leaving a hotspot needs a longer quiet period, so a brief hiccup doesn't turn everything back on.
    var leaveSeconds = 20.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DetectionConfig()
        useMeteredFlag = try c.decodeIfPresent(Bool.self, forKey: .useMeteredFlag) ?? d.useMeteredFlag
        hotspotAddressPrefixes = try c.decodeIfPresent([String].self, forKey: .hotspotAddressPrefixes) ?? d.hotspotAddressPrefixes
        settleSeconds = try c.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? d.settleSeconds
        leaveSeconds = try c.decodeIfPresent(Double.self, forKey: .leaveSeconds) ?? d.leaveSeconds
    }
}

struct Config: Codable {
    static let currentVersion = 2
    var configVersion = Config.currentVersion
    var mode: SaverMode = .auto
    var notifications = true
    var detection = DetectionConfig()
    var controls: [Control] = Config.defaultControls

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configVersion = try c.decodeIfPresent(Int.self, forKey: .configVersion) ?? 1
        mode = try c.decodeIfPresent(SaverMode.self, forKey: .mode) ?? .auto
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        detection = try c.decodeIfPresent(DetectionConfig.self, forKey: .detection) ?? DetectionConfig()
        controls = try c.decodeIfPresent([Control].self, forKey: .controls) ?? Config.defaultControls
    }

    /// Brings an older settings file up to date. Returns true if anything changed.
    mutating func migrate() -> Bool {
        guard configVersion < Config.currentVersion else { return false }
        if configVersion < 2 {
            // Grammarly's own helper reloads its updater within seconds, so pausing it did nothing.
            controls.removeAll { $0.id == "grammarlyupdater" && $0.labels == ["com.grammarly.ProjectLlama.UpdateService"] }
            // Add only what version 2 introduced, so defaults you deleted stay deleted.
            let newIn2: Set<String> = ["superhumango"]
            let have = Set(controls.map(\.id))
            controls += Config.defaultControls.filter { newIn2.contains($0.id) && !have.contains($0.id) }
        }
        configVersion = Config.currentVersion
        return true
    }

    static let sync = "Cloud sync"
    static let updates = "Automatic app updates"
    static let optional = "Other syncing apps"

    /// Anything not installed on this Mac is simply hidden from the menu.
    static let defaultControls: [Control] = [
        Control(id: "onedrive", name: "OneDrive", group: sync, kind: .app, autoPause: true,
                bundleId: "com.microsoft.OneDrive"),
        Control(id: "dropbox", name: "Dropbox", group: sync, kind: .app, autoPause: true,
                bundleId: "com.getdropbox.dropbox"),
        Control(id: "googledrive", name: "Google Drive", group: sync, kind: .app, autoPause: true,
                bundleId: "com.google.drivefs"),
        Control(id: "box", name: "Box Drive", group: sync, kind: .app, autoPause: true,
                bundleId: "com.box.desktop"),
        Control(id: "creativecloud", name: "Adobe Creative Cloud", group: sync, kind: .app, autoPause: true,
                bundleId: "com.adobe.acc.AdobeCreativeCloud"),

        Control(id: "msautoupdate", name: "Microsoft Office updates", group: updates, kind: .launchAgents,
                autoPause: true, labels: ["com.microsoft.update.agent"],
                processNames: ["Microsoft Update Assistant", "Microsoft AutoUpdate.app/Contents/MacOS/Microsoft AutoUpdate"]),
        Control(id: "onedriveupdater", name: "OneDrive updater", group: updates, kind: .launchAgents,
                autoPause: true, labels: ["com.microsoft.OneDriveStandaloneUpdater"]),
        Control(id: "googleupdater", name: "Google Chrome updater", group: updates, kind: .launchAgents,
                autoPause: true,
                labels: ["com.google.GoogleUpdater.wake", "com.google.keystone.agent", "com.google.keystone.xpcservice"]),
        Control(id: "dropboxupdater", name: "Dropbox updater", group: updates, kind: .launchAgents,
                autoPause: true,
                labels: ["com.dropbox.DropboxUpdater.wake", "com.dropbox.dropboxmacupdate.agent",
                         "com.dropbox.dropboxmacupdate.xpcservice"]),
        Control(id: "zoomupdater", name: "Zoom updater", group: updates, kind: .launchAgents,
                autoPause: true, labels: ["us.zoom.updater", "us.zoom.updater.login.check"]),
        Control(id: "adobeupdater", name: "Adobe Acrobat updater", group: updates, kind: .launchAgents,
                autoPause: true, labels: ["com.adobe.ARMDCHelper.*"]),
        Control(id: "asideupdater", name: "Aside updater", group: updates, kind: .launchAgents,
                autoPause: true,
                labels: ["at.studio.AsideUpdater.wake", "at.studio.asidekeystone.agent",
                         "at.studio.asidekeystone.xpcservice"]),

        Control(id: "acrobatsync", name: "Adobe Acrobat cloud sync", group: optional, kind: .app,
                autoPause: false, bundleId: "com.adobe.AdobeResourceSynchronizer"),
        Control(id: "zotero", name: "Zotero", group: optional, kind: .app, autoPause: false,
                bundleId: "org.zotero.zotero"),
        Control(id: "papers", name: "Papers", group: optional, kind: .app, autoPause: false,
                bundleId: "com.ReadCube.Papers"),
        Control(id: "superhumango", name: "Superhuman Go (Grammarly)", group: optional, kind: .app,
                autoPause: false, bundleId: "com.grammarly.ProjectLlama",
                note: "Writing assistant; sends what you type for suggestions."),
    ]
}

struct PauseRecord: Codable {
    /// true = paused because of the hotspot, so it is turned back on automatically when you leave it.
    var auto: Bool
    var at: Date
    /// For launch agents: exactly which ones were unloaded.
    var labels: [String]?
    /// Enough to turn it back on even if its entry is later removed from the settings file.
    var kind: ControlKind?
    var bundleId: String?
    var name: String?
    /// An app that was asked to quit but hadn't yet when we stopped waiting.
    var pendingPIDs: [Int32]?

    init(auto: Bool, at: Date, labels: [String]?, kind: ControlKind? = nil, bundleId: String? = nil,
         name: String? = nil, pendingPIDs: [Int32]? = nil) {
        self.auto = auto; self.at = at; self.labels = labels
        self.kind = kind; self.bundleId = bundleId; self.name = name; self.pendingPIDs = pendingPIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        kind = try? c.decodeIfPresent(ControlKind.self, forKey: .kind)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        pendingPIDs = try c.decodeIfPresent([Int32].self, forKey: .pendingPIDs)
    }
}

struct SaverState: Codable {
    var paused: [String: PauseRecord] = [:]
    /// Items you turned back on during the current hotspot session; left alone until you disconnect.
    var overrides: Set<String> = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decodeIfPresent([String: PauseRecord].self, forKey: .paused) ?? [:]
        overrides = try c.decodeIfPresent(Set<String>.self, forKey: .overrides) ?? []
    }
}
