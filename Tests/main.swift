// Unit tests for Hotspot Saver. Run with ./test.sh — read-only: no apps are quit and nothing is unloaded.
import AppKit

var fails = 0
var skips = 0
func check(_ name: String, _ cond: Bool) {
    print(cond ? "PASS" : "FAIL", name)
    if !cond { fails += 1 }
}
func skip(_ name: String) { print("SKIP", name); skips += 1 }
func v4(_ a: [UInt8], _ mask: UInt32) -> IPv4Info {
    IPv4Info(name: "en0", address: a.map(String.init).joined(separator: "."), octets: a, mask: mask)
}

// MARK: iPhone hotspot subnet: 172.20.10.2–14 on a /28 only

check("172.20.10.2/28 is an iPhone hotspot", isIPhoneHotspot(v4([172, 20, 10, 2], 0xFFFF_FFF0)))
check("172.20.10.14/28 is an iPhone hotspot", isIPhoneHotspot(v4([172, 20, 10, 14], 0xFFFF_FFF0)))
check("172.20.10.1/28 (the phone itself) is not a client address", !isIPhoneHotspot(v4([172, 20, 10, 1], 0xFFFF_FFF0)))
check("172.20.10.15/28 (broadcast) is not", !isIPhoneHotspot(v4([172, 20, 10, 15], 0xFFFF_FFF0)))
check("172.20.10.57/24 office VLAN is not", !isIPhoneHotspot(v4([172, 20, 10, 57], 0xFFFF_FF00)))
check("172.20.10.2/24 office VLAN is not", !isIPhoneHotspot(v4([172, 20, 10, 2], 0xFFFF_FF00)))
check("172.20.11.2/28 is not", !isIPhoneHotspot(v4([172, 20, 11, 2], 0xFFFF_FFF0)))
check("tunnel interface names are recognised",
      isTunnelInterface("utun8") && isTunnelInterface("bridge100") && !isTunnelInterface("en0"))

// MARK: settings file

let v1 = """
{"mode":"auto","controls":[
 {"id":"onedrive","name":"OneDrive","group":"Cloud sync","kind":"app","autoPause":true,"bundleId":"com.microsoft.OneDrive"},
 {"id":"grammarlyupdater","name":"Grammarly updater","group":"Automatic app updates","kind":"launchAgents","autoPause":true,"labels":["com.grammarly.ProjectLlama.UpdateService"]},
 {"id":"mine","kind":"shell","pauseCommand":"true","resumeCommand":"true"}]}
"""
var cfg = try! JSONDecoder().decode(Config.self, from: Data(v1.utf8))
check("a version-1 file decodes as version 1", cfg.configVersion == 1)
check("migrate reports a change", cfg.migrate())
check("migration removes the ineffective Grammarly updater", !cfg.controls.contains { $0.id == "grammarlyupdater" })
check("migration keeps the user's own items", cfg.controls.contains { $0.id == "mine" })
check("migration adds the item new in version 2", cfg.controls.contains { $0.id == "superhumango" })
check("migration doesn't duplicate items", cfg.controls.filter { $0.id == "onedrive" }.count == 1)
check("migrating twice is a no-op", cfg.configVersion == 2 && !cfg.migrate())

var trimmed = try! JSONDecoder().decode(
    Config.self, from: Data(#"{"controls":[{"id":"onedrive","kind":"app","bundleId":"com.microsoft.OneDrive"}]}"#.utf8))
_ = trimmed.migrate()
check("migration doesn't bring back defaults the user deleted",
      Set(trimmed.controls.map(\.id)) == ["onedrive", "superhumango"])

let empty = try! JSONDecoder().decode(Config.self, from: Data("{}".utf8))
check("an empty settings file gets every default and a 20 s leave delay",
      empty.controls.count == Config.defaultControls.count && empty.detection.leaveSeconds == 20)
check("defaults never target device-management, security or VPN agents",
      !Config.defaultControls.flatMap { $0.labels ?? [] }.contains { label in
          ["intune", "wdav", "defender", "paloalto", "citrix", "lakeside", "ws1", "beyondtrust", "jamf", "crowdstrike"]
              .contains { label.lowercased().contains($0) }
      })

// MARK: state file

let dec = JSONDecoder()
dec.dateDecodingStrategy = .iso8601
let partial = try! dec.decode(SaverState.self, from: Data(#"{"paused":{"dropbox":{}}}"#.utf8))
check("a record with missing fields still decodes (auto = true)",
      partial.paused["dropbox"]?.auto == true && partial.overrides.isEmpty)
let orphans = try! dec.decode(SaverState.self, from: Data(
    #"{"paused":{"gone":{"auto":true,"kind":"app","bundleId":"com.example.x","name":"X"},"legacy":{"auto":true}}}"#.utf8))
check("a record keeps what it needs to be resumed without its settings entry",
      orphans.paused["gone"]?.bundleId == "com.example.x" && orphans.paused["gone"]?.kind == .app)
check("an old record without a kind still decodes", orphans.paused["legacy"]?.kind == nil)

// MARK: pop-up wording

let d = Config.defaultControls
let pick = { (ids: [String]) in ids.compactMap { id in d.first { $0.id == id } } }
check("describe: two apps plus updaters",
      AppController.describe(pick(["onedrive", "dropbox", "msautoupdate", "zoomupdater"])) == "OneDrive, Dropbox and 2 app updaters")
check("describe: a single updater by name",
      AppController.describe(pick(["msautoupdate"])) == "Microsoft Office updates")

// MARK: Open at login

let loginPlist = LoginItem.plist(executable: "/Applications/Hotspot Saver.app/Contents/MacOS/HotspotSaver")
check("login item uses the app's label and starts it in menu-bar mode",
      loginPlist["Label"] as? String == AppInfo.bundleID
          && (loginPlist["ProgramArguments"] as? [String]) == ["/Applications/Hotspot Saver.app/Contents/MacOS/HotspotSaver", "--menubar"])
check("login item restarts after a crash but not after Quit",
      (loginPlist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false && loginPlist["RunAtLoad"] as? Bool == true)
check("login item plist serializes", (try? PropertyListSerialization.data(fromPropertyList: loginPlist, format: .xml, options: 0)) != nil)
let oldConfig = try! JSONDecoder().decode(Config.self, from: Data("{}".utf8))
check("older settings files haven't asked about Open at login yet", oldConfig.askedAboutLogin == false)

// MARK: launch-agent matching against this Mac's real plists (read-only; skipped if not installed)

if FileManager.default.fileExists(atPath: Paths.config.path) {
    let engine = Engine()
    let adobe = engine.resolvedAgents(d.first { $0.id == "adobeupdater" }!)
    if adobe.isEmpty { skip("Adobe updater wildcard (Acrobat not installed)") }
    else { check("Adobe updater wildcard resolves to ARMDCHelper agents", adobe.allSatisfy { $0.label.hasPrefix("com.adobe.ARMDCHelper.") }) }
    let zoom = engine.resolvedAgents(d.first { $0.id == "zoomupdater" }!)
    if zoom.isEmpty { skip("Zoom updater agents (Zoom not installed)") }
    else { check("Zoom updater agents are matched by their plist Label", zoom.allSatisfy { $0.label.hasPrefix("us.zoom.updater") }) }
} else {
    skip("launch-agent matching (Hotspot Saver not installed yet)")
}

print(fails == 0 ? "ALL PASSED" + (skips > 0 ? " (\(skips) skipped)" : "") : "\(fails) FAILED")
exit(fails == 0 ? 0 : 1)
