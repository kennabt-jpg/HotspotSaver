import AppKit

/// The menu-bar app: watches the network, pauses/resumes things, and draws the menu.
///
/// Threading: everything here runs on the main thread except the blocks sent to `work`,
/// a serial queue that does all pausing and resuming in order. Anything that decides
/// *what* to resume reads the records inside `work`, so it always runs after any pause
/// still in progress.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = Engine()
    private let detector = Detector()
    private let toast = Toast()
    private var statusItem: NSStatusItem!
    private let work = DispatchQueue(label: "local.HotspotSaver.work")
    private let launchedAt = Date()

    private var net: NetInfo?              // latest reading, for display
    private var decided = false            // have we committed a decision from a connected path yet?
    private var tethered = false           // the committed decision
    private var saverActive = false
    private var settleItem: DispatchWorkItem?
    private var inFlight: [String: Int] = [:]   // id → operations under way (they can overlap)
    private var quitting = false

    private func mark(_ ids: [String]) { ids.forEach { inFlight[$0, default: 0] += 1 } }
    private func unmark(_ ids: [String]) {
        for id in ids { if let n = inFlight[id] { inFlight[id] = n > 1 ? n - 1 : nil } }
    }
    private func isBusy(_ id: String) -> Bool { inFlight[id] != nil }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            Log.write("Already running; this copy is exiting.")
            // Ask the running copy to say where it is, so opening it again doesn't look like nothing happened.
            DistributedNotificationCenter.default().postNotificationName(
                IPC.command, object: "0 hello", userInfo: nil, deliverImmediately: true)
            usleep(200_000)
            exit(0)
        }

        // "Turned back on for this session" choices don't carry over a restart.
        engine.clearOverrides()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        detector.config = engine.config.detection
        detector.onUpdate = { [weak self] info in self?.networkChanged(info) }
        detector.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(remoteCommand(_:)), name: IPC.command, object: nil,
            suspensionBehavior: .deliverImmediately)

        Log.write("Started (mode: \(engine.config.mode.rawValue))")
        // RunLoop.perform, not DispatchQueue.main.async: a modal alert inside a main-queue block
        // would stop the network monitor and timers (also on the main queue) until it's answered.
        RunLoop.main.perform { self.firstRunChecks() }
    }

    // MARK: first run and Open at login

    private func firstRunChecks() {
        if LoginItem.isTranslocated { showMoveToApplicationsAlert(); return }
        // If the app was moved, keep Open at login pointing at this copy.
        if LoginItem.isEnabled && LoginItem.pointsElsewhere && LoginItem.inApplicationsFolder {
            setLoginItem(true)
        }
        guard !engine.config.askedAboutLogin else { return }
        engine.updateConfig { $0.askedAboutLogin = true }
        if LoginItem.isEnabled { return }        // set up already (install.sh)
        let alert = NSAlert()
        alert.messageText = "Open Hotspot Saver when you log in?"
        alert.informativeText = "It needs to be running to notice when you tether to your phone. "
            + "You can change this anytime from its menu-bar icon."
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setLoginItem(true) }
        if engine.state.paused.isEmpty {
            notify("Hotspot Saver is running",
                   "Its icon is in the menu bar. It pauses cloud sync and app updaters automatically when you tether to your phone.")
        }
    }

    private func showMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move Hotspot Saver to your Applications folder"
        alert.informativeText = "macOS is running a temporary copy of Hotspot Saver, so it can't set itself to open at login. "
            + "Click Quit. Then, in Finder, drag Hotspot Saver by itself into your Applications folder. If it's already there, "
            + "drag it to the Desktop and then back into Applications. Then open it from Applications."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Keep Running for Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { beginQuit(then: nil) }
    }

    @objc private func toggleLoginItem() {
        if LoginItem.isTranslocated { showMoveToApplicationsAlert(); return }
        if LoginItem.isEnabled && LoginItem.blockedInSettings { LoginItem.openSettings(); return }
        setLoginItem(!LoginItem.isEnabled)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try LoginItem.enable() } else { try LoginItem.disable() }
            Log.write("Open at login \(on ? "on" : "off")")
        } catch {
            Log.write("Couldn't change Open at login: \(error.localizedDescription)")
            notify("Couldn't change Open at login", error.localizedDescription)
        }
    }

    // MARK: network → saver mode

    private var pendingTarget: Bool?    // the decision the settle timer is counting down toward

    private func cancelPending() {
        settleItem?.cancel()
        settleItem = nil
        pendingTarget = nil
    }

    private func networkChanged(_ info: NetInfo) {
        guard !quitting else { return }
        net = info
        // No connection (asleep, rejoining Wi-Fi, out of signal) is not "left the hotspot":
        // keep the current decision until we see a real network again.
        guard info.connected else { cancelPending(); updateIcon(); return }
        // Same answer as the current decision: nothing to change, and any pending change is called off.
        if decided && info.tethered == tethered { cancelPending(); updateIcon(); return }
        // Already counting down toward this answer: let the timer run. macOS repeats identical
        // path updates every few seconds, so restarting the timer here would postpone it forever.
        if pendingTarget == info.tethered && settleItem != nil { updateIcon(); return }
        cancelPending()
        let settle = max(0.5, engine.config.detection.settleSeconds)
        let leaving = decided && tethered && !info.tethered
        let delay = leaving ? max(settle, engine.config.detection.leaveSeconds) : settle
        let target = info.tethered
        pendingTarget = target
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleItem = nil
            self.pendingTarget = nil
            guard let now = self.detector.current(), now.connected else { return }
            if now.tethered == target || !self.decided { self.commit(now) }
        }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func commit(_ info: NetInfo) {
        guard !quitting else { return }
        net = info
        let first = !decided
        decided = true
        let changed = info.tethered != tethered
        tethered = info.tethered
        if first || changed {
            Log.write(info.tethered
                      ? "Hotspot detected: \(info.reasons.joined(separator: "; ")) [\(info.summary)]"
                      : "Not on a hotspot [\(info.summary)]")
        }
        if first { reconcile() }
        evaluate(force: first)
    }

    private var shouldBeActive: Bool {
        switch engine.config.mode {
        case .on: return true
        case .off: return false
        case .auto: return tethered
        }
    }

    private func evaluate(force: Bool = false) {
        guard !quitting else { return }
        guard decided || engine.config.mode == .on else { updateIcon(); return }
        let want = shouldBeActive
        if want && (!saverActive || force) {
            saverActive = true
            let gen = engine.bumpGeneration()
            Log.write("Saver mode ON")
            pauseEligible(gen: gen, auto: true, title: tethered ? "Hotspot detected" : "Data saver on")
            scheduleLoginSweeps(gen: gen)
        } else if !want && (saverActive || force) {
            let wasActive = saverActive
            saverActive = false
            engine.bumpGeneration()            // stops any pause batch still running
            engine.clearOverrides()
            if wasActive { Log.write("Saver mode OFF") }
            resumeOnQueue(title: wasActive ? (tethered ? "Data saver off" : "Back on a regular connection") : nil,
                          markOverride: false) { $0.filter { $0.value.auto }.map(\.key) }
        }
        updateIcon()
    }

    /// Sync apps started at login often appear a minute or two after we do; sweep again for them.
    private func scheduleLoginSweeps(gen: Int) {
        guard Date().timeIntervalSince(launchedAt) < 300 else { return }
        for delay in [45.0, 120.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.saverActive, !self.quitting, self.engine.generation == gen else { return }
                self.pauseEligible(gen: gen, auto: true, title: "Hotspot detected")
            }
        }
    }

    /// Pause every item set to pause automatically (except ones you turned back on this session).
    private func pauseEligible(gen: Int, auto: Bool, title: String?,
                               completion: (([(Control, ActionResult)]) -> Void)? = nil) {
        // In-flight items are not skipped: the work queue is serial, and the loop below re-checks
        // each item's real state, so a batch queued behind another still does the right thing.
        let targets = engine.availableControls().filter { $0.autoPause }
        guard !targets.isEmpty else { completion?([]); return }
        mark(targets.map(\.id))
        work.async { [engine] in
            let loaded = engine.loadedLabels()
            var results: [(Control, ActionResult)] = []
            for c in targets {
                guard engine.generation == gen else { break }      // saver turned off meanwhile
                guard !engine.isOverridden(c.id), engine.status(c, loaded: loaded) == .running else { continue }
                results.append((c, engine.pause(c, auto: auto)))
            }
            DispatchQueue.main.async {
                self.unmark(targets.map(\.id))
                self.updateIcon()
                let paused = results.filter { $0.1.ok }.map(\.0)
                let stuck = results.filter { !$0.1.ok && $0.0.kind == .app }.map(\.0)
                if let title, !paused.isEmpty {
                    self.notify(title, "Paused \(AppController.describe(paused)). Click the menu-bar icon to turn any back on.")
                }
                if !stuck.isEmpty && auto && self.saverActive && self.engine.generation == gen {
                    self.notify("Couldn't pause \(AppController.describe(stuck)) yet",
                                "It didn't quit (probably busy). Trying again in a minute.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                        guard self.saverActive, !self.quitting, self.engine.generation == gen else { return }
                        self.pauseEligible(gen: gen, auto: true, title: "Hotspot detected")
                    }
                }
                completion?(results)
            }
        }
    }

    /// Resume the records chosen by `select`, which runs on the work queue after any pending pause.
    private func resumeOnQueue(title: String?, markOverride: Bool,
                               completion: (([(Control, ActionResult)]) -> Void)? = nil,
                               select: @escaping ([String: PauseRecord]) -> [String]) {
        let gen = engine.generation
        work.async { [engine] in
            let ids = select(engine.state.paused)
            DispatchQueue.main.async { self.mark(ids) }
            var results: [(Control, ActionResult)] = []
            for id in ids {
                guard let c = engine.resumable(id) else {
                    // An old record with too little information to act on: stop showing it as paused.
                    engine.dropRecord(id)
                    Log.write("'\(id)' was listed as paused but isn't in the settings file and can't be turned back on automatically; removed from the list")
                    let ghost = Control(id: id, name: id, group: "Other", kind: .app, autoPause: false)
                    results.append((ghost, ActionResult(ok: false, message: "not in settings; turn it back on yourself")))
                    continue
                }
                if markOverride && engine.generation == gen { engine.addOverride(id) }
                results.append((c, engine.resume(c)))
            }
            DispatchQueue.main.async {
                self.unmark(ids)
                self.updateIcon()
                let failed = results.filter { !$0.1.ok }.map(\.0)
                let resumed = results.filter { $0.1.ok }.map(\.0)
                if !failed.isEmpty {
                    self.notify("Couldn't turn back on \(AppController.describe(failed))",
                                "Click it in the menu-bar menu to try again. Details are in the log.")
                } else if let title, !resumed.isEmpty {
                    self.notify(title, "Turned back on \(AppController.describe(resumed)).")
                }
                completion?(results)
            }
        }
    }

    /// Drop records for things that were turned back on outside Hotspot Saver.
    private func reconcile() {
        for (c, rec) in engine.reconcile(skipping: Set(inFlight.keys)) {
            // An app you reopened yourself during this session stays on until you leave the hotspot.
            if saverActive && c.kind == .app && rec.at >= launchedAt { engine.addOverride(c.id) }
            Log.write("\(c.name) is on again (turned on outside Hotspot Saver); no longer tracked as paused.")
        }
    }

    @objc private func appLaunched(_ n: Notification) {
        guard !quitting,
              let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bid = app.bundleIdentifier else { return }
        for c in engine.config.controls where c.kind == .app && c.bundleId == bid {
            guard let rec = engine.record(c.id), !isBusy(c.id) else { continue }
            if let pending = rec.pendingPIDs, pending.contains(where: processAlive) { continue }
            engine.dropRecord(c.id)
            // Only right after login can a launch be the app's own login item; later, it's you.
            if rec.at >= launchedAt || Date().timeIntervalSince(launchedAt) >= 300 {
                if saverActive { engine.addOverride(c.id) }
                Log.write("\(c.name) was opened again, so it stays on for this hotspot session.")
            } else if saverActive && c.autoPause {
                // Paused before a restart and started again by its login item: pause it again.
                Log.write("\(c.name) started again after a restart; pausing it again shortly.")
                let gen = engine.generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.saverActive, !self.quitting, self.engine.generation == gen else { return }
                    self.pauseEligible(gen: gen, auto: true, title: "Hotspot detected")
                }
            }
        }
        updateIcon()
    }

    // MARK: menu actions

    @objc private func toggleControl(_ sender: NSMenuItem) {
        guard !quitting, let id = sender.representedObject as? String, let c = engine.control(id),
              !isBusy(id) else { return }
        let loaded = engine.loadedLabels()
        let pausing = engine.status(c, loaded: loaded) == .running && !engine.needsRetry(c, loaded: loaded)
        let active = saverActive
        if !pausing && active { engine.addOverride(id) }   // decided now, before any sweep can run
        mark([id])
        work.async { [engine] in
            let r = pausing ? engine.pause(c, auto: active) : engine.resume(c)
            DispatchQueue.main.async {
                self.unmark([id])
                self.updateIcon()
                if !r.ok {
                    self.notify(pausing ? "Couldn't pause \(c.name)" : "Couldn't turn on \(c.name)", r.message)
                }
            }
        }
    }

    @objc private func pauseAllNow() {
        guard !quitting else { return }
        engine.clearOverrides()
        pauseEligible(gen: engine.generation, auto: saverActive, title: "Paused")
    }

    @objc private func resumeAllNow() {
        guard !quitting else { return }
        if saverActive { engine.state.paused.keys.forEach { engine.addOverride($0) } }
        resumeOnQueue(title: nil, markOverride: saverActive) { Array($0.keys) }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = SaverMode(rawValue: raw) else { return }
        if !engine.updateConfig({ $0.mode = m }) { notify("Not saved", "The settings file has an error, so this lasts only until Hotspot Saver restarts.") }
        Log.write("Mode set to \(m.rawValue)")
        evaluate()
    }

    @objc private func toggleAutoPause(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let saved = engine.updateConfig { cfg in
            if let i = cfg.controls.firstIndex(where: { $0.id == id }) { cfg.controls[i].autoPause.toggle() }
        }
        if !saved { notify("Not saved", "The settings file has an error, so this lasts only until Hotspot Saver restarts.") }
    }

    @objc private func toggleNotifications() {
        engine.updateConfig { $0.notifications.toggle() }
    }

    @objc private func editSettings() {
        runTool("/usr/bin/open", ["-t", Paths.config.path], timeout: 10)
    }

    @objc private func reloadSettings() {
        cancelPending()
        engine.reloadConfig()
        detector.config = engine.config.detection
        if let err = engine.configError {
            let alert = NSAlert()
            alert.messageText = "The settings file has an error"
            alert.informativeText = "Hotspot Saver keeps using its previous settings until it's fixed.\n\n\(err)"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        if let info = detector.current(), info.connected {
            if decided && info.tethered != tethered {
                networkChanged(info)       // a change still goes through the normal settle/leave delay
                evaluate()                 // mode changes apply now, against the current decision
            } else {
                commit(info)
            }
        } else {
            evaluate()
        }
        Log.write("Settings reloaded")
    }

    @objc private func openLog() {
        runTool("/usr/bin/open", ["-a", "Console", Paths.log.path], timeout: 10)
    }

    @objc private func openNetworkSettings() {
        let pane = net?.interfaceKind == "Wi-Fi"
            ? "x-apple.systempreferences:com.apple.wifi-settings-extension"
            : "x-apple.systempreferences:com.apple.Network-Settings.extension"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }

    @objc private func quitApp() { beginQuit(then: nil) }

    /// Turn everything back on, then exit. `then` gets anything that couldn't be turned back on
    /// and runs on the main thread just before exiting.
    private func beginQuit(then: (([String]) -> Void)?) {
        guard !quitting else { return }
        quitting = true
        cancelPending()
        engine.bumpGeneration()            // stop any pause batch in progress
        toast.dismiss(animated: false)
        Log.write("Quitting: turning everything back on first")
        updateIcon()
        // Queued behind any work in progress, so it sees every record that work writes.
        work.async { [engine] in
            var failed: [String] = []
            for id in Array(engine.state.paused.keys).sorted() {
                guard let c = engine.resumable(id) else { failed.append("\(id) (not in settings)"); continue }
                let r = engine.resume(c)
                if !r.ok { failed.append("\(c.name): \(r.message)") }
            }
            engine.clearOverrides()
            DispatchQueue.main.async {
                if let then {
                    then(failed)
                } else if !failed.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some things couldn't be turned back on"
                    alert.informativeText = failed.joined(separator: "\n")
                        + "\n\nHotspot Saver will try again the next time it starts, or you can reopen them yourself."
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                // Give a distributed-notification reply a moment to go out before exiting.
                DispatchQueue.main.asyncAfter(deadline: .now() + (then == nil ? 0 : 0.5)) { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if !quitting { reconcile() }
        menu.removeAllItems()
        buildMenu(menu)
        updateIcon()
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.addItem(infoItem(headerText, bold: true))
        if let info = net { menu.addItem(infoItem(info.summary)) }
        if let info = net, info.connected, info.tethered {
            menu.addItem(infoItem("Detected by " + info.reasons.joined(separator: "; ")))
        }
        if engine.configError != nil { menu.addItem(infoItem("⚠︎ Settings file has an error; using \(engine.configSource)")) }
        let orphans = engine.orphanedRecordIDs()
        if !orphans.isEmpty {
            menu.addItem(infoItem("⚠︎ Paused but missing from settings: \(orphans.joined(separator: ", "))"))
        }
        if saverActive, let info = net, info.connected, !info.lowDataMode {
            let ldm = NSMenuItem(title: "Turn on Low Data Mode for this network…",
                                 action: #selector(openNetworkSettings), keyEquivalent: "")
            ldm.target = self
            ldm.image = symbolImage("exclamationmark.triangle", color: .systemYellow)
            ldm.toolTip = "Low Data Mode asks macOS and apps that honor it (iCloud Photos, for example) to hold back "
                + "background data on this network. You only need to switch it on once per hotspot."
            menu.addItem(ldm)
        }
        menu.addItem(.separator())

        let loaded = engine.loadedLabels()
        let controls = engine.availableControls()
        var groups: [String] = []
        for c in controls where !groups.contains(c.group) { groups.append(c.group) }
        for g in groups {
            menu.addItem(NSMenuItem.sectionHeader(title: g))
            for c in controls where c.group == g {
                menu.addItem(controlItem(c, status: engine.status(c, loaded: loaded),
                                         partial: engine.needsRetry(c, loaded: loaded)))
            }
        }
        menu.addItem(.separator())

        let pauseAll = NSMenuItem(title: "Pause everything now", action: #selector(pauseAllNow), keyEquivalent: "")
        pauseAll.target = self
        pauseAll.toolTip = "Pauses every item that is set to pause automatically."
        pauseAll.isEnabled = !quitting
        menu.addItem(pauseAll)
        let resumeAll = NSMenuItem(title: "Turn everything back on", action: #selector(resumeAllNow), keyEquivalent: "")
        resumeAll.target = self
        resumeAll.isEnabled = !quitting && !engine.state.paused.isEmpty
        menu.addItem(resumeAll)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for (mode, title) in [(SaverMode.auto, "Automatically on a hotspot"),
                              (.on, "Always (as if on a hotspot)"),
                              (.off, "Never (pause only what I click)")] {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = engine.config.mode == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Save data", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        let autoMenu = NSMenu()
        autoMenu.autoenablesItems = false
        for c in controls {
            let item = NSMenuItem(title: c.name, action: #selector(toggleAutoPause(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.id
            item.state = c.autoPause ? .on : .off
            autoMenu.addItem(item)
        }
        let autoItem = NSMenuItem(title: "Pause automatically on a hotspot", action: nil, keyEquivalent: "")
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)

        let notifyItem = NSMenuItem(title: "Show a pop-up when things pause or resume",
                                    action: #selector(toggleNotifications), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = engine.config.notifications ? .on : .off
        menu.addItem(notifyItem)

        let blocked = LoginItem.isEnabled && LoginItem.blockedInSettings
        let loginItem = NSMenuItem(title: blocked ? "Open at login (switched off in System Settings…)" : "Open at login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled && !blocked ? .on : .off
        menu.addItem(loginItem)

        let more = NSMenu()
        for (title, sel) in [("Edit settings file…", #selector(editSettings)),
                             ("Reload settings", #selector(reloadSettings)),
                             ("Open log", #selector(openLog))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            more.addItem(item)
        }
        let moreItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        moreItem.submenu = more
        menu.addItem(moreItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: quitting ? "Quitting…" : "Quit Hotspot Saver",
                              action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.isEnabled = !quitting
        if !engine.state.paused.isEmpty && !quitting {
            quit.toolTip = "Turns everything back on before quitting."
            if #available(macOS 14.4, *) { quit.subtitle = "Turns everything back on first" }
        }
        menu.addItem(quit)
    }

    private var headerText: String {
        if quitting { return "Turning everything back on…" }
        guard decided else {
            return net?.connected == false ? "No connection yet" : "Checking your connection…"
        }
        let manual = engine.state.paused.values.filter { !$0.auto }.count
        let autoLeft = engine.state.paused.count - manual
        if net?.connected == false {
            return saverActive ? "No connection · still saving data" : "No connection"
        }
        switch (tethered, engine.config.mode) {
        case (true, .off): return "On a hotspot · saver is off"
        case (true, _): return "On a hotspot · saving data"
        case (false, .on): return "Saver forced on"
        default:
            if autoLeft > 0 {
                return inFlight.isEmpty ? "Regular connection · \(autoLeft) couldn't be turned back on"
                                        : "Regular connection · turning things back on…"
            }
            return manual > 0 ? "Regular connection · \(manual) paused by hand" : "Regular connection · nothing paused"
        }
    }

    private func controlItem(_ c: Control, status: ControlStatus, partial: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: c.name, action: #selector(toggleControl(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = c.id
        let detail: String
        if isBusy(c.id) || quitting {
            detail = "Working…"
            item.image = symbolImage("hourglass", color: .secondaryLabelColor)
            item.isEnabled = false
        } else {
            switch status {
            case .running where partial:
                detail = "Partly off · click to turn back on"
                item.image = symbolImage("exclamationmark.circle.fill", color: .systemOrange)
            case .running:
                detail = "On · click to pause"
                item.image = symbolImage("circle.fill", color: .systemGreen)
            case .paused:
                detail = "Paused · click to turn back on"
                item.image = symbolImage("pause.circle.fill", color: .systemOrange)
            case .stopped:
                detail = c.kind == .app ? "Not running · click to open" : "Off · click to turn on"
                item.image = symbolImage("circle", color: .tertiaryLabelColor)
            }
        }
        if #available(macOS 14.4, *) { item.subtitle = detail } else { item.title = "\(c.name) — \(detail)" }
        var tip = c.autoPause ? "Pauses automatically on a hotspot." : "Doesn't pause automatically; click to pause it yourself."
        if let note = c.note { tip += "\n\(note)" }
        item.toolTip = tip
        return item
    }

    private func infoItem(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = bold ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
                        : NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        return item
    }

    private func symbolImage(_ name: String, color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name = saverActive ? "personalhotspot.circle.fill" : "personalhotspot"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)
            ?? NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: AppInfo.name)
        img?.isTemplate = true
        button.image = img
        let n = engine.state.paused.count
        button.title = n > 0 ? "\(n)" : ""
        button.toolTip = saverActive ? "Hotspot Saver: saving data (\(n) paused)" : "Hotspot Saver: regular connection"
    }

    // MARK: pop-up messages

    private func notify(_ title: String, _ body: String) {
        guard engine.config.notifications, !quitting else { return }
        toast.show(title: title, body: body, near: statusItem?.button)
    }

    /// "OneDrive, Dropbox and 7 app updaters"
    static func describe(_ controls: [Control]) -> String {
        let updaters = controls.filter { $0.group == Config.updates }
        var parts = controls.filter { $0.group != Config.updates }.map(\.name)
        if updaters.count == 1 { parts.append(updaters[0].name) }
        if updaters.count > 1 { parts.append("\(updaters.count) app updaters") }
        if parts.count <= 1 { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    // MARK: commands from the CLI

    @objc private func remoteCommand(_ n: Notification) {
        guard let text = n.object as? String else { return }
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return }
        let rid = parts[0], verb = parts[1]
        let arg = parts.count > 2 ? parts[2] : ""
        let reply: (String) -> Void = { msg in
            DistributedNotificationCenter.default().postNotificationName(
                IPC.reply, object: "\(rid)\n\(msg)", userInfo: nil, deliverImmediately: true)
        }
        let lines: ([(Control, ActionResult)]) -> String = { results in
            results.isEmpty ? "Nothing to do." : results.map { "\($0.0.name): \($0.1.message)" }.joined(separator: "\n")
        }
        if quitting { reply("Hotspot Saver is quitting."); return }

        switch (verb, arg) {
        case ("pause", "all"):
            engine.clearOverrides()
            pauseEligible(gen: engine.generation, auto: saverActive, title: nil) { reply(lines($0)) }
        case ("resume", "all"):
            if saverActive { engine.state.paused.keys.forEach { engine.addOverride($0) } }
            resumeOnQueue(title: nil, markOverride: saverActive, completion: { reply(lines($0)) }) { Array($0.keys) }
        case ("pause", _), ("resume", _):
            guard let c = verb == "resume" ? engine.resumable(arg) : engine.control(arg) else {
                reply("Unknown item '\(arg)'. Run 'hotspot-saver status' to see the ids.")
                return
            }
            let active = saverActive
            if verb == "resume" && active { engine.addOverride(c.id) }
            mark([c.id])
            work.async { [engine] in
                let r = verb == "pause" ? engine.pause(c, auto: active) : engine.resume(c)
                DispatchQueue.main.async {
                    self.unmark([c.id])
                    self.updateIcon()
                    reply("\(c.name): \(r.message)")
                }
            }
        case ("mode", _):
            guard let m = SaverMode(rawValue: arg) else { reply("Mode must be auto, on or off."); return }
            engine.updateConfig { $0.mode = m }
            Log.write("Mode set to \(m.rawValue) (from command line)")
            evaluate()
            work.async { DispatchQueue.main.async { reply("Mode set to \(m.rawValue). Saver is \(self.saverActive ? "ON" : "off").") } }
        case ("reload", _):
            reloadSettings()
            work.async { DispatchQueue.main.async { reply("Settings reloaded. Saver is \(self.saverActive ? "ON" : "off").") } }
        case ("menu", _):
            // Text dump of the real menu, for checking it without a screen.
            let m = NSMenu()
            menuNeedsUpdate(m)
            func dump(_ menu: NSMenu, _ indent: String) -> [String] {
                menu.items.flatMap { item -> [String] in
                    if item.isSeparatorItem { return [indent + "────"] }
                    var line = indent + (item.state == .on ? "✓ " : "  ") + item.title
                    if #available(macOS 14.4, *), let s = item.subtitle { line += "   [\(s)]" }
                    if !item.isEnabled && item.action != nil { line += "   (disabled)" }
                    return [line] + (item.submenu.map { dump($0, indent + "      ") } ?? [])
                }
            }
            reply(dump(m, "").joined(separator: "\n"))
        case ("quit", _):
            beginQuit { failed in
                reply(failed.isEmpty
                      ? "Turned everything back on and quit. Reopen \(AppInfo.name) from ~/Applications to start it again."
                      : "Quit, but couldn't turn these back on:\n" + failed.joined(separator: "\n"))
            }
        case ("hello", _):
            notify("Hotspot Saver is already running", "Click its icon in the menu bar (two linked rings) to use it.")
        case ("state", _):
            reply("saver \(saverActive ? "ON" : "off"), \(decided ? (tethered ? "on a hotspot" : "not on a hotspot") : "no decision yet")")
        default:
            reply("Unknown command '\(verb)'")
        }
    }
}
