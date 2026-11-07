# Hotspot Saver

A small macOS menu-bar app. When you tether to your phone, it pauses the things that quietly use a lot of data: cloud sync apps (OneDrive, Dropbox, Google Drive, Box, Adobe Creative Cloud) and the background auto-updaters for Office, Chrome, Zoom, Adobe and others. When you're back on a regular network, it turns back on everything it paused. You can turn any single item back on (or off) from the menu at any time.

## Installing

You need macOS 14 (Sonoma) or later and Apple's Command Line Tools. If you don't have the tools yet, install them with:

```bash
xcode-select --install
```

No Xcode project is needed. From the repository folder, run:

```bash
./install.sh
```

That builds the app and installs it to `~/Applications/Hotspot Saver.app`. It also does two other things:

- adds the `hotspot-saver` command to `~/.local/bin`;
- adds a LaunchAgent (`~/Library/LaunchAgents/local.HotspotSaver.plist`) that starts the app when you log in.

Rerun `./install.sh` after any change; it's safe to rerun.

## Using it

The icon is in the menu bar (a hotspot symbol). It fills in when Saver is active, and a number beside it shows how many things are paused.

Click it to see:

- **What connection you're on**, and why it decided it's a hotspot.
- **Each item and its state.** Click an item to flip it.
  - green: on
  - orange pause symbol: paused
  - orange **!**: partly off (click to retry)
  - empty circle: not running (apps) or off (updaters)
  - hourglass: working
- **Turning something back on during a hotspot session** keeps it on until you leave the hotspot (or choose *Pause everything now*); it won't get paused again in the meantime. Reopening a paused app yourself counts the same.
- **Pause everything now** pauses every item ticked under *Pause automatically on a hotspot*. **Turn everything back on** resumes everything that's paused. Anything you pause by hand while Saver isn't active stays paused until you turn it back on; the header then shows "N paused by hand".
- **Save data:**
  - *Automatically on a hotspot* (default)
  - *Always (as if on a hotspot)*: handy on plane or hotel Wi-Fi, or an Android hotspot
  - *Never (pause only what I click)*
- **Pause automatically on a hotspot**: tick which items get paused for you. Zotero, Papers, Superhuman Go and Acrobat sync are listed but off by default.
- **Quit** turns everything back on first. After quitting, it stays off until your next login. Reopen it from `~/Applications` if you want it sooner.

A small pop-up under the icon tells you when things pause or resume. Click it to dismiss, or switch it off in the menu. macOS doesn't allow regular notifications from an app you build yourself, so it uses its own pop-up.

## One-time setup: turn on Low Data Mode for your hotspot

Hotspot Saver can't control Apple's own background traffic (iCloud, Photos, system updates), and macOS offers no way for an app to turn Low Data Mode on. Do this once per hotspot and macOS remembers it:

- **iPhone over Wi-Fi:** System Settings → Wi-Fi → **Details…** next to your iPhone → **Low Data Mode** on.
- **iPhone over USB:** System Settings → Network → **iPhone USB** → **Details…** → **Low Data Mode** on.

While Saver is active on a network without Low Data Mode, the menu shows **Turn on Low Data Mode for this network…**. It opens Wi-Fi settings, or Network settings for a USB connection.

What Low Data Mode actually does on a Mac is only partly documented. Apple documents that **iCloud Photos sync pauses**, and says the system defers "discretionary" background work. OneDrive for Mac reportedly pauses sync on Low Data Mode networks. Software Update and iCloud Drive behaviour isn't documented by Apple, so treat it as "likely helps", not a guarantee.

## How it detects tethering

It decides you're on a hotspot when either:

1. **macOS marks the connection as metered.** It does this for an iPhone Personal Hotspot over Wi-Fi, USB or Bluetooth.
   - **VPNs:** it usually still works with a VPN connected, since VPNs built on Apple's networking framework pass the flag through. That isn't guaranteed for every VPN, so check the menu the first time you tether with your VPN on.
   - **Some carriers:** it also works where the Mac gets no `172.20.10.x` address (T-Mobile US, for example).
2. **Your Mac has an iPhone-hotspot address:** `172.20.10.2–14`, with the small /28 netmask an iPhone hotspot uses. Office networks that merely use `172.20.10.x` addresses are not mistaken for a hotspot.

A brief loss of connection (waking from sleep, a dead zone, a phone call) doesn't count as leaving the hotspot. It waits for 20 seconds of a confirmed regular network before turning things back on.

**Android hotspots:** macOS doesn't mark these as metered. Either use *Save data → Always* while on one, or add its gateway prefix to the settings file (see below).

## What it pauses (default list)

Anything not installed on your Mac is hidden from the menu.

| Item | How it's paused | Paused automatically |
|---|---|---|
| OneDrive, Dropbox, Google Drive, Box Drive, Adobe Creative Cloud | Quit normally (as if you chose Quit); reopened in the background afterward | Yes |
| Microsoft Office updates (AutoUpdate) | Its background launch agent is unloaded (and a running AutoUpdate or Update Assistant is stopped), then reloaded later | Yes |
| OneDrive, Chrome, Dropbox, Zoom, Adobe Acrobat and Aside updaters | Their background launch agents are unloaded, then reloaded later | Yes |
| Adobe Acrobat cloud sync, Zotero, Papers, Superhuman Go | Quit / reopen | No (click to pause) |

Things to know:

- **While OneDrive or Dropbox is paused, files that are only in the cloud won't open.** Click the item in the menu to turn it back on; it stays on for the rest of that hotspot session.
- **Sync apps are never force-quit.** If one is busy and doesn't quit within 30 seconds, it's left running; while Saver is active it's retried a minute later. If it quits on its own later, it's still treated as paused.
- **Not touched:** Teams, Zoom calls, Slack, Outlook, browsers, and anything your organization manages (device-management, security and VPN software).
- **Self-updating apps:** apps that update themselves from inside (Slack, for example) can't be paused separately from quitting them.

## Command line

`./install.sh` puts the `hotspot-saver` command in `~/.local/bin`. If that folder isn't on your `PATH`, add this line to `~/.zshrc`, or run `~/.local/bin/hotspot-saver` directly:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

To see what's on and what's paused:

```bash
hotspot-saver status
```

Other commands:

| Command | What it does |
|---|---|
| `detect` | Exit status 0 if on a hotspot, 1 if not |
| `pause <id\|all>` | `all` = every item ticked under *Pause automatically on a hotspot* |
| `resume <id\|all>` | `all` = everything that's paused |
| `mode auto\|on\|off` | *Automatically* / *Always* / *Never* |
| `reload` | Re-reads the settings file |
| `quit` | Turns everything back on, then quits the app |
| `menu` | Prints the menu as text |

- The ids are shown by `status` (or `list`).
- `mode`, `reload`, `quit` and `menu` need the menu-bar app to be running. `status`, `detect`, `pause` and `resume` also work without it.
- These commands work from Raycast or Shortcuts too.

## Settings file

`~/Library/Application Support/HotspotSaver/config.json` is created with the defaults on first launch. To edit it, open the menu → Advanced → **Edit settings file…**, then **Reload settings** (or run `hotspot-saver reload`).

Top-level keys:

| Key | What it holds |
|---|---|
| `mode` | `"auto"`, `"on"` or `"off"` |
| `notifications` | The pop-ups; default `true` |
| `detection` | Detection settings (below) |
| `controls` | The list of items |

Each entry in `controls` looks like one of these:

```json
{ "id": "spotify", "name": "Spotify", "group": "Other syncing apps",
  "kind": "app", "bundleId": "com.spotify.client", "autoPause": true }

{ "id": "someupdater", "name": "Some updater", "group": "Automatic app updates",
  "kind": "launchAgents", "labels": ["com.example.updater*"], "autoPause": true }

{ "id": "custom", "name": "My thing", "group": "Other", "kind": "shell",
  "pauseCommand": "…", "resumeCommand": "…", "statusCommand": "…", "autoPause": false }
```

Defaults and optional keys:

- **Defaults:** `name` defaults to the id, `group` to "Other", and `autoPause` to `true`.
- **`processNames`** (optional): extra processes to stop when pausing, matched against the full command line.
- **`note`** (optional): shown in the item's tooltip.
- **Launch agents:** a `launchAgents` item matches the `Label` of plists in `~/Library/LaunchAgents` and `/Library/LaunchAgents`; `*` wildcards are allowed.
- **Shell items:** a `statusCommand` that exits 0 means "on".

To find an app's `bundleId`:

```bash
osascript -e 'id of app "Spotify"'
```

Detection settings live under `"detection"`:

| Key | Default | What it does |
|---|---|---|
| `useMeteredFlag` | `true` | Use macOS's metered flag. |
| `hotspotAddressPrefixes` | `["172.20.10."]` | `"172.20.10."` means the iPhone rule; keep it when you add others. Any other prefix is matched against the gateway (or your Mac's own address). For an Android hotspot, add the start of the gateway address the menu shows while you're on it, e.g. `"192.168.43."`. |
| `settleSeconds` | `4` (minimum 0.5) | How long a change has to last before it acts, e.g. after you join a hotspot. |
| `leaveSeconds` | `20` | How long a regular connection has to last before it decides you've left a hotspot and turns things back on. |

If the file has a mistake, the app keeps using its previous settings and says so in the menu.

## Troubleshooting

- **Log:** menu → Advanced → Open log, or `~/Library/Logs/HotspotSaver.log`. Every pause and resume is recorded.
- **Something stayed off:** click it in the menu, or run `hotspot-saver resume all`.
- **"Paused but missing from settings":** an item was removed from `config.json` while paused. *Turn everything back on* (or `hotspot-saver resume all`) usually still restores it, because the app remembers how it paused it. For a `shell` item, add it back to the settings file first.

## Rebuilding and removing

Run these from the repository folder:

- `./install.sh`: builds and (re)installs, as described above.
- `./build.sh`: only builds `build/Hotspot Saver.app`, without installing it.
- `./test.sh`: runs the unit tests. They're read-only: nothing is quit or unloaded.
- `./uninstall.sh`: turns everything back on and removes the app, the command and the LaunchAgent. Add `--all` to also delete settings and logs.

## Alternatives

If you'd rather block *any* app's network use on a per-connection basis, look at TripMode (made for exactly this; paid) or Little Snitch (per-app firewall with per-network profiles). Hotspot Saver doesn't block traffic. It only quits or unloads the specific things listed above, so there's nothing to install at the system level.
