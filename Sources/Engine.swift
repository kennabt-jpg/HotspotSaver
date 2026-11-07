import AppKit

enum ControlStatus: String {
    case running = "on"
    case paused = "paused"
    case stopped = "not running"
}

struct ActionResult {
    var ok: Bool
    var message: String
}

/// Knows how to check, pause and resume each control, and remembers what it paused.
/// Thread-safe: the menu reads it on the main thread while pauses run on a background queue.
final class Engine: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var _config = Config()
    private var _state = SaverState()
    private var _configError: String?
    private var _generation = 0
    private var haveGoodConfig = false
    private(set) var configSource = "settings file"
    private static let lastGood = Paths.support.appendingPathComponent("config.lastgood.json")
    private let uid = getuid()

    init() {
        Paths.ensure()
        reloadConfig()
        _state = Engine.loadState()
    }

    var config: Config { lock.lock(); defer { lock.unlock() }; return _config }
    var state: SaverState { lock.lock(); defer { lock.unlock() }; return _state }
    var configError: String? { lock.lock(); defer { lock.unlock() }; return _configError }

    /// Bumped whenever saver mode turns on or off (or the app quits), so a batch of pauses
    /// that is still running can tell that it should stop.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }
    @discardableResult func bumpGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        _generation += 1
        return _generation
    }

    // MARK: config & state persistence

    func reloadConfig() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: Paths.config) else {
            _config = Config()
            _configError = nil
            haveGoodConfig = true
            saveConfigLocked()
            return
        }
        do {
            var cfg = try JSONDecoder().decode(Config.self, from: data)
            let migrated = cfg.migrate()
            _config = cfg
            _configError = nil
            haveGoodConfig = true
            configSource = "settings file"
            if migrated { Log.write("Settings file updated to version \(cfg.configVersion)") }
            saveConfigLocked()
        } catch {
            _configError = "\(error)"
            // Keep the settings already in use; at launch, fall back to the last good copy.
            if !haveGoodConfig {
                if let d = try? Data(contentsOf: Engine.lastGood), let cfg = try? JSONDecoder().decode(Config.self, from: d) {
                    _config = cfg
                    configSource = "last good copy of your settings"
                } else {
                    _config = Config()
                    configSource = "built-in defaults"
                }
                haveGoodConfig = true
            } else if configSource == "settings file" {
                configSource = "previous settings"
            }
            Log.write("Settings file has an error; using \(configSource) until it is fixed: \(error)")
        }
    }

    /// Applies a change; returns false if it couldn't be saved (the settings file has an error).
    @discardableResult func updateConfig(_ change: (inout Config) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        change(&_config)
        return saveConfigLocked()
    }

    @discardableResult private func saveConfigLocked() -> Bool {
        guard _configError == nil else { return false }  // never overwrite a file the user is mid-edit on
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(_config) else { return false }
        do { try data.write(to: Paths.config, options: .atomic) } catch { return false }
        try? data.write(to: Engine.lastGood, options: .atomic)
        return true
    }

    private static func loadState() -> SaverState {
        guard let data = try? Data(contentsOf: Paths.state) else { return SaverState() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            return try dec.decode(SaverState.self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = Paths.support.appendingPathComponent("state.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: Paths.state, to: aside)
            Log.write("state.json couldn't be read (\(error)); moved it to \(aside.lastPathComponent). Anything it listed as paused needs turning back on by hand.")
            return SaverState()
        }
    }

    private func saveStateLocked() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(_state) { try? data.write(to: Paths.state, options: .atomic) }
    }

    func mutateState(_ change: (inout SaverState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&_state)
        saveStateLocked()
    }

    func control(_ id: String) -> Control? { config.controls.first { $0.id == id } }

    /// The control for a paused item, rebuilt from its record if it has left the settings file.
    func resumable(_ id: String) -> Control? {
        if let c = control(id) { return c }
        guard let rec = record(id), let kind = rec.kind else { return nil }
        let name = rec.name ?? id
        switch kind {
        case .app:
            guard let b = rec.bundleId else { return nil }
            return Control(id: id, name: name, group: "Other", kind: .app, autoPause: false, bundleId: b)
        case .launchAgents:
            guard let labels = rec.labels, !labels.isEmpty else { return nil }
            return Control(id: id, name: name, group: "Other", kind: .launchAgents, autoPause: false, labels: labels)
        case .shell:
            return nil
        }
    }

    /// A launch-agent item where some recorded agents are still unloaded (a resume partly failed).
    func needsRetry(_ c: Control, loaded: Set<String>) -> Bool {
        c.kind == .launchAgents && (record(c.id)?.labels ?? []).contains { !loaded.contains($0) }
    }
    func record(_ id: String) -> PauseRecord? { state.paused[id] }
    func isOverridden(_ id: String) -> Bool { state.overrides.contains(id) }
    func addOverride(_ id: String) { mutateState { $0.overrides.insert(id) } }
    func clearOverrides() { mutateState { $0.overrides.removeAll() } }
    func dropRecord(_ id: String) { mutateState { $0.paused[id] = nil } }

    /// Paused items whose entry has disappeared from the settings file (kept, never silently forgotten).
    func orphanedRecordIDs() -> [String] {
        let ids = Set(config.controls.map(\.id))
        return state.paused.keys.filter { !ids.contains($0) }.sorted()
    }

    // MARK: availability & status

    func available(_ c: Control) -> Bool {
        switch c.kind {
        case .app:
            guard let b = c.bundleId else { return false }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) != nil
        case .launchAgents:
            return !resolvedAgents(c).isEmpty
        case .shell:
            return c.pauseCommand != nil && c.resumeCommand != nil
        }
    }

    func availableControls() -> [Control] { config.controls.filter { available($0) } }

    /// Labels currently loaded in this user's launchd session.
    func loadedLabels() -> Set<String> {
        let r = runTool("/bin/launchctl", ["list"], timeout: 10)
        var labels = Set<String>()
        for line in r.output.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 3 { labels.insert(String(cols[2])) }
        }
        return labels
    }

    func status(_ c: Control, loaded: Set<String>? = nil) -> ControlStatus {
        let rec = record(c.id)
        switch c.kind {
        case .app:
            if appPIDs(c).isEmpty { return rec != nil ? .paused : .stopped }
            return .running
        case .launchAgents:
            let loaded = loaded ?? loadedLabels()
            if resolvedAgents(c).contains(where: { loaded.contains($0.label) }) { return .running }
            return rec != nil ? .paused : .stopped
        case .shell:
            if let s = c.statusCommand {
                if shell(s, timeout: 3).status == 0 { return .running }
                return rec != nil ? .paused : .stopped
            }
            return rec != nil ? .paused : .running
        }
    }

    /// Forget pauses that something else has already undone (you reopened the app, or logging
    /// out and back in reloaded the agents). Skips items that are mid-action.
    /// Returns each dropped control with the record it had.
    func reconcile(skipping busy: Set<String>) -> [(control: Control, record: PauseRecord)] {
        let paused = state.paused          // snapshot before the (slow) launchctl call
        guard !paused.isEmpty else { return [] }
        let loaded = loadedLabels()
        var dropped: [(Control, PauseRecord)] = []
        for (id, rec) in paused where !busy.contains(id) {
            guard let c = control(id) else { continue }  // unknown to the settings: keep it
            switch c.kind {
            case .app:
                if let pending = rec.pendingPIDs, pending.contains(where: processAlive) { continue }  // still quitting
                if !appPIDs(c).isEmpty { dropped.append((c, rec)) }
                else if rec.pendingPIDs != nil { mutateState { $0.paused[id]?.pendingPIDs = nil } }  // quit late: now a normal pause
            case .launchAgents:
                let mine = rec.labels ?? resolvedAgents(c).map(\.label)
                if !mine.isEmpty && mine.allSatisfy({ loaded.contains($0) }) { dropped.append((c, rec)) }
            case .shell:
                if let s = c.statusCommand, shell(s, timeout: 3).status == 0 { dropped.append((c, rec)) }
            }
        }
        mutateState { st in
            for (c, rec) in dropped where st.paused[c.id]?.at == rec.at { st.paused[c.id] = nil }
        }
        return dropped
    }

    // MARK: pause / resume

    func pause(_ c: Control, auto: Bool) -> ActionResult {
        let result: ActionResult
        switch c.kind {
        case .app: result = pauseApp(c, auto: auto)
        case .launchAgents: result = pauseAgents(c, auto: auto)
        case .shell: result = pauseShell(c, auto: auto)
        }
        Log.write("Pause \(c.name)\(auto ? " (hotspot)" : ""): \(result.message)")
        return result
    }

    func resume(_ c: Control) -> ActionResult {
        let result: ActionResult
        switch c.kind {
        case .app: result = resumeApp(c)
        case .launchAgents: result = resumeAgents(c)
        case .shell: result = resumeShell(c)
        }
        Log.write("Resume \(c.name): \(result.message)")
        return result
    }

    /// Writes (or merges into) the pause record. Called before acting, so an interruption
    /// can never leave something off without a record of it.
    private func setRecord(_ c: Control, auto: Bool, labels: [String]? = nil) {
        mutateState {
            let old = $0.paused[c.id]
            var merged: [String]? = nil
            if labels != nil || old?.labels != nil {
                merged = Array(Set(labels ?? []).union(old?.labels ?? [])).sorted()
            }
            // Once paused by hand, it stays a manual pause (not auto-resumed when leaving a hotspot).
            let isAuto = (old?.auto ?? true) && auto
            // A running app means any earlier pause is over, so it gets a fresh timestamp.
            let at = c.kind == .app ? Date() : (old?.at ?? Date())
            $0.paused[c.id] = PauseRecord(auto: isAuto, at: at, labels: merged, kind: c.kind,
                                          bundleId: c.bundleId, name: c.name, pendingPIDs: nil)
            $0.overrides.remove(c.id)
        }
    }

    // apps

    private func runningApps(_ c: Control) -> [NSRunningApplication] {
        guard let b = c.bundleId else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: b)
            .filter { processAlive($0.processIdentifier) }
    }

    private func appPIDs(_ c: Control) -> [pid_t] { runningApps(c).map(\.processIdentifier) }

    /// Asks the app to quit, the same as choosing Quit from its menu. Sync apps are never
    /// force-killed: a killed sync client can relaunch itself or interrupt an upload.
    private func pauseApp(_ c: Control, auto: Bool) -> ActionResult {
        guard c.bundleId != nil else { return ActionResult(ok: false, message: "no bundleId in settings") }
        let apps = runningApps(c)
        guard !apps.isEmpty else { return ActionResult(ok: false, message: "wasn't running") }
        setRecord(c, auto: auto)
        let pids = apps.map(\.processIdentifier)
        for wait in [20.0, 10.0] {
            apps.forEach { _ = $0.terminate() }
            let deadline = uptime() + wait
            while uptime() < deadline && pids.contains(where: processAlive) { usleep(250_000) }
            if !pids.contains(where: processAlive) { break }
        }
        if pids.contains(where: processAlive) {
            // Keep the record: if it quits later we still know to reopen it.
            mutateState { $0.paused[c.id]?.pendingPIDs = pids }
            return ActionResult(ok: false, message: "hasn't quit after 30 s (probably busy); will check again")
        }
        killExtras(c)
        return ActionResult(ok: true, message: "quit")
    }

    private func resumeApp(_ c: Control) -> ActionResult {
        guard let b = c.bundleId else { return ActionResult(ok: false, message: "no bundleId in settings") }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) == nil {
            dropRecord(c.id)
            return ActionResult(ok: true, message: "no longer installed; nothing to reopen")
        }
        let r = runTool("/usr/bin/open", ["-g", "-b", b], timeout: 30)
        if r.status == 0 {
            dropRecord(c.id)
            return ActionResult(ok: true, message: "reopened")
        }
        return ActionResult(ok: false, message: "couldn't reopen: \(r.output)")
    }

    // launch agents

    private struct AgentPlist { let label: String; let path: String }
    private var agentCache: (key: String, agents: [AgentPlist])?

    /// Every launch-agent plist this user's session can load, keyed by its real Label.
    /// User agents come first so they win over a same-named system one.
    private func allAgents() -> [AgentPlist] {
        let dirs = [Paths.home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents"]
        let fm = FileManager.default
        let key = dirs.map { dir -> String in
            let m = (try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
            return "\(dir)=\(m?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        lock.lock()
        if let cache = agentCache, cache.key == key { lock.unlock(); return cache.agents }
        lock.unlock()

        var out: [AgentPlist] = []
        var seen = Set<String>()
        for dir in dirs {
            for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".plist") {
                let path = "\(dir)/\(f)"
                guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
                      dict["Program"] != nil || dict["ProgramArguments"] != nil else { continue }
                let label = (dict["Label"] as? String) ?? String(f.dropLast(6))
                if seen.insert(label).inserted { out.append(AgentPlist(label: label, path: path)) }
            }
        }
        lock.lock(); agentCache = (key, out); lock.unlock()
        return out
    }

    func resolvedAgents(_ c: Control) -> [(label: String, plist: String)] {
        let patterns = c.labels ?? []
        return allAgents()
            .filter { a in patterns.contains { fnmatch($0, a.label, 0) == 0 } }
            .map { ($0.label, $0.path) }
    }

    private func pauseAgents(_ c: Control, auto: Bool) -> ActionResult {
        let loaded = loadedLabels()
        let targets = resolvedAgents(c).filter { loaded.contains($0.label) }
        guard !targets.isEmpty else { return ActionResult(ok: false, message: "wasn't loaded") }
        let previous = record(c.id)
        setRecord(c, auto: auto, labels: targets.map(\.label))
        for t in targets {
            runTool("/bin/launchctl", ["bootout", "gui/\(uid)/\(t.label)"], timeout: 15)
        }
        killExtras(c)
        // Trust launchd's real state, not bootout's exit status.
        var after = loadedLabels()
        for _ in 0..<8 where targets.contains(where: { after.contains($0.label) }) {
            usleep(250_000)
            after = loadedLabels()
        }
        let done = targets.map(\.label).filter { !after.contains($0) }
        let failed = targets.map(\.label).filter { after.contains($0) }
        let keep = Array(Set(previous?.labels ?? []).union(done)).sorted()
        mutateState {
            if keep.isEmpty { $0.paused[c.id] = nil } else { $0.paused[c.id]?.labels = keep }
        }
        if done.isEmpty { return ActionResult(ok: false, message: "couldn't unload \(failed.joined(separator: ", "))") }
        return ActionResult(ok: true, message: "unloaded \(done.joined(separator: ", "))"
                            + (failed.isEmpty ? "" : "; still loaded: \(failed.joined(separator: ", "))"))
    }

    private func resumeAgents(_ c: Control) -> ActionResult {
        // Reload exactly the agents that were unloaded, found by their Label wherever they live.
        let byLabel = Dictionary(allAgents().map { ($0.label, $0.path) }, uniquingKeysWith: { first, _ in first })
        let wanted = record(c.id)?.labels ?? resolvedAgents(c).map(\.label)
        let loaded = loadedLabels()
        var done: [String] = []
        var gone: [String] = []
        var failures: [String: String] = [:]
        for label in wanted where !loaded.contains(label) {
            guard let plist = byLabel[label] else { gone.append(label); continue }
            let r = runTool("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist], timeout: 15)
            if r.status == 0 || loadedLabels().contains(label) { done.append(label) }
            else { failures[label] = r.output }
        }
        if !gone.isEmpty {
            Log.write("\(c.name): no launch-agent file for \(gone.joined(separator: ", ")) any more (app removed?); not reloaded")
        }
        if failures.isEmpty {
            dropRecord(c.id)
            var msg = done.isEmpty ? "already loaded" : "reloaded \(done.joined(separator: ", "))"
            if !gone.isEmpty { msg += "; no longer installed: \(gone.joined(separator: ", "))" }
            return ActionResult(ok: true, message: msg)
        }
        mutateState { $0.paused[c.id]?.labels = failures.keys.sorted() }
        return ActionResult(ok: false, message: "couldn't reload "
                            + failures.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: "; "))
    }

    private func killExtras(_ c: Control) {
        for name in c.processNames ?? [] where !name.isEmpty {
            runTool("/usr/bin/pkill", ["-U", "\(uid)", "-f", NSRegularExpression.escapedPattern(for: name)], timeout: 10)
        }
    }

    // shell

    private func pauseShell(_ c: Control, auto: Bool) -> ActionResult {
        guard let cmd = c.pauseCommand else { return ActionResult(ok: false, message: "no pauseCommand") }
        let hadRecord = record(c.id) != nil
        setRecord(c, auto: auto)
        let r = shell(cmd)
        if r.status != 0 && !hadRecord { dropRecord(c.id) }
        return ActionResult(ok: r.status == 0, message: r.status == 0 ? "ran pause command" : "pause command failed: \(r.output)")
    }

    private func resumeShell(_ c: Control) -> ActionResult {
        guard let cmd = c.resumeCommand else { return ActionResult(ok: false, message: "no resumeCommand") }
        let r = shell(cmd)
        if r.status == 0 { dropRecord(c.id) }
        return ActionResult(ok: r.status == 0, message: r.status == 0 ? "ran resume command" : "resume command failed: \(r.output)")
    }
}
