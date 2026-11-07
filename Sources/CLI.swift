import AppKit

/// `hotspot-saver <command>`: check status or pause/resume items from Terminal, Raycast, or Shortcuts.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let verb = args[0]
        switch verb {
        case "status", "list":
            return status()
        case "detect":
            let engine = Engine()
            guard let info = Detector.detectOnce(config: engine.config.detection) else {
                print("Couldn't read the network state."); return 2
            }
            print(info.tethered ? "HOTSPOT: \(info.reasons.joined(separator: "; "))" : "not a hotspot")
            print(info.summary)
            return info.tethered ? 0 : 1
        case "pause", "resume":
            guard args.count >= 2 else { usage(); return 2 }
            return act(verb, args[1])
        case "mode":
            guard args.count >= 2, SaverMode(rawValue: args[1]) != nil else {
                print("Usage: hotspot-saver mode auto|on|off"); return 2
            }
            return forwardOrFail("mode \(args[1])")
        case "reload":
            return forwardOrFail("reload")
        case "quit":
            return forwardOrFail("quit")
        case "menu":
            return forwardOrFail("menu")
        default:
            usage()
            return verb == "help" || verb == "-h" || verb == "--help" ? 0 : 2
        }
    }

    static func usage() {
        print("""
        Hotspot Saver: pauses cloud sync and auto-updaters while you're on a phone hotspot.

          hotspot-saver status            what's on, what's paused, and whether you're tethered
          hotspot-saver detect            exit 0 if on a hotspot, 1 if not
          hotspot-saver pause  <id|all>   pause one item (ids are shown by 'status')
          hotspot-saver resume <id|all>   turn one item, or everything, back on
          hotspot-saver mode auto|on|off  auto = pause on hotspots; on = always; off = never
          hotspot-saver reload            re-read ~/Library/Application Support/HotspotSaver/config.json
          hotspot-saver quit              turn everything back on, then quit the menu-bar app
          hotspot-saver menu              print the menu-bar menu as text
        """)
    }

    private static var appRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .contains { $0.processIdentifier != getpid() && processAlive($0.processIdentifier) }
    }

    /// Hand a command to the running menu-bar app so its state stays in sync.
    private static func forward(_ command: String, timeout: TimeInterval = 120) -> String? {
        let rid = UUID().uuidString
        var answer: String?
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: IPC.reply, object: nil, queue: nil) { n in
            guard let text = n.object as? String, text.hasPrefix(rid + "\n") else { return }
            answer = String(text.dropFirst(rid.count + 1))
        }
        center.postNotificationName(IPC.command, object: "\(rid) \(command)", userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(timeout)
        while answer == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        center.removeObserver(token)
        return answer
    }

    private static func forwardOrFail(_ command: String) -> Int32 {
        guard appRunning else { print("The Hotspot Saver menu-bar app isn't running."); return 1 }
        guard let r = forward(command) else { print("The menu-bar app didn't answer."); return 1 }
        print(r)
        return 0
    }

    private static func status() -> Int32 {
        let engine = Engine()
        let info = Detector.detectOnce(config: engine.config.detection)
        print("Connection: \(info?.summary ?? "unknown")")
        if let info, info.tethered {
            print("Hotspot:    YES (\(info.reasons.joined(separator: "; ")))")
        } else {
            print("Hotspot:    no")
        }
        var modeLine = "Mode:       \(engine.config.mode.rawValue)"
        if appRunning, let s = forward("state", timeout: 3) { modeLine += "  (menu-bar app: \(s))" }
        else { modeLine += "  (menu-bar app not running)" }
        print(modeLine)
        if let e = engine.configError { print("Settings:   ERROR, using defaults: \(e)") }
        let orphans = engine.orphanedRecordIDs()
        if !orphans.isEmpty { print("Warning:    paused but missing from settings: \(orphans.joined(separator: ", "))") }

        let loaded = engine.loadedLabels()
        let controls = engine.availableControls()
        var groups: [String] = []
        for c in controls where !groups.contains(c.group) { groups.append(c.group) }
        for g in groups {
            print("\n\(g)")
            for c in controls where c.group == g {
                let st = engine.status(c, loaded: loaded)
                let id = c.id.padding(toLength: 18, withPad: " ", startingAt: 0)
                let name = c.name.padding(toLength: 28, withPad: " ", startingAt: 0)
                let label = (st == .stopped && c.kind != .app) ? "off" : st.rawValue
                let state = label.padding(toLength: 13, withPad: " ", startingAt: 0)
                print("  \(id)\(name)\(state)\(c.autoPause ? "auto-pause" : "")")
            }
        }
        return 0
    }

    private static func act(_ verb: String, _ id: String) -> Int32 {
        if appRunning {
            guard let r = forward("\(verb) \(id)") else { print("The menu-bar app didn't answer."); return 1 }
            print(r)
            return r.hasPrefix("Unknown") ? 2 : 0
        }
        let engine = Engine()
        let targets: [Control]
        if id == "all" {
            targets = verb == "pause"
                ? engine.availableControls().filter(\.autoPause)
                : engine.state.paused.keys.compactMap { engine.resumable($0) }
        } else if let c = (verb == "resume" ? engine.resumable(id) : engine.control(id)) {
            targets = [c]
        } else {
            print("Unknown item '\(id)'. Run 'hotspot-saver status' to see the ids.")
            return 2
        }
        if targets.isEmpty { print("Nothing to \(verb)."); return 0 }
        for c in targets {
            let r = verb == "pause" ? engine.pause(c, auto: false) : engine.resume(c)
            print("\(c.name): \(r.message)")
        }
        return 0
    }
}
