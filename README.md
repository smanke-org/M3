# M3 Tracker: Mac Mouse Mileage Tracker

A macOS menu bar app that tracks cumulative mouse/trackpad movement distance,
keystrokes, and left/right click counts. Counters persist across restarts and
reboots (stored via `UserDefaults`, which is backed by disk).

## Install

[**Download the latest release**](https://github.com/smanke/M3/releases/latest)
— a `.dmg` signed with a Developer ID certificate and notarized by Apple, so
it opens cleanly with no Gatekeeper warning. Open the disk image, drag
`M3 Tracker.app` to `/Applications`, and launch it. On first launch, grant
Accessibility (Input Monitoring) access when macOS prompts — see
[Required permission](#required-permission) below.

The app checks for updates on demand from the menu bar dropdown
("Check for Updates…") — see [Auto-update](#auto-update) below.

## How it works

- `EventMonitor` uses `NSEvent.addGlobalMonitorForEvents` to observe pointer
  movement, clicks, and key-down events system-wide. Trackpad-driven cursor
  movement generates the same `mouseMoved`/`*Dragged` events as a physical
  mouse, so both are counted identically — there's no way (or need) to tell
  them apart.
- Distance is accumulated in Cocoa points and converted to real-world units
  using the standard 72-points-per-inch definition (there's no API to query a
  pointing device's physical DPI, so this is the same convention AppKit itself
  uses for point-based coordinates).
- `MetricsStore` persists counters to `UserDefaults` every 5 seconds and on
  quit. `MileageHistoryStore` separately buckets mileage by hour/day for the
  charts.
- The menu bar shows feet (to the tenths place) while under a mile, then
  switches to miles (to the hundredths place).
- Clicking the menu bar item shows mileage charts (Today by Hour, By Day,
  Year to Date) using Swift Charts, plus Preferences and Quit.
- The Preferences window shows current stats and has buttons to reset
  mileage, keystrokes, clicks, or everything — each asks for confirmation
  before clearing. It also has a "Launch at Login" checkbox, backed by
  `SMAppService` (`LaunchAtLoginController.swift`).

## Combined mileage across Macs

Every Mac signed in to the same Apple Account shares its totals through iCloud
Drive, so each one can show **This Mac** and **All Macs** side by side. The
dropdown shows both, and its charts combine every Mac. The menu bar title shows
this Mac by default; Preferences › "Menu bar shows" switches it to All Macs
(falling back to this Mac while iCloud Drive is off, rather than showing other
Macs' totals that are no longer being kept current). An All Macs title is
prefixed with Σ so it can't be mistaken for this Mac's figure; that marker can
be turned off in Preferences, and never appears on the fallback. Preferences
also lists each
Mac with its mileage and when it last synced.

`CloudSync.swift` does this with plain files, one per Mac:

```
iCloud Drive/M3 Tracker/Devices/<device id>.json
```

- **Each Mac writes only its own file** and reads everyone else's, so there are
  no sync conflicts to resolve. Files hold cumulative totals, so a stale,
  repeated, or delayed write can never double-count. This Mac's own file is
  ignored when reading; its live totals are used instead.
- **No iCloud entitlement is needed.** The app isn't sandboxed, so this is
  ordinary file I/O into iCloud Drive — no App ID, provisioning profile, or
  entitlements file. It does need iCloud Drive turned on; when it's off, All
  Macs says so and the charts fall back to this Mac.
- **The device ID** is a hash of the hardware UUID: stable across reinstalls,
  not carried to a new Mac by Migration Assistant (so two Macs never share a
  file), and the raw hardware identifier never reaches iCloud.
- **Charts** are merged on this Mac's calendar. A Mac in another time zone has
  different day boundaries, so each of its buckets is assigned to the local day
  (or hour) it overlaps most, rather than splitting a day in two.
- **Writes** happen once a minute when something changed, and immediately on
  reset, sleep, and quit. Reads happen on the same timer and when the menu opens.
  File access is coordinated and kept off the main thread.
- **Resets affect this Mac only.** Its file drops to zero; the other Macs keep
  their own counts.
- **Retiring a Mac:** its file keeps counting, since those miles happened.
  Delete its file from `iCloud Drive/M3 Tracker/Devices` to remove it — the
  name shown in Preferences identifies which Mac is which.
- **Evicted files:** if iCloud Drive offloads a file to save space, the app asks
  for it back and keeps using the last-known totals meanwhile.

One known limitation: a Mac set up with Migration Assistant from another Mac
that is *still in use* inherits the old Mac's totals, so miles from before the
migration count twice. Resetting on the new Mac fixes it.

`M3_SYNC_FOLDER` redirects the folder, which the tests use so they never touch
real iCloud data. A debug build shares the installed app's device ID, so set it
when running one alongside the installed app.

## Mileage per app

Mileage, clicks, and keystrokes are also credited to whichever app **has focus**
at the time — so you can see how far you mouse in Photoshop versus Safari. That's
the frontmost app, not the app under the cursor: moving across a background
window still counts toward the app you're working in.

- The menu dropdown's **Top Apps** card ranks the top five by mileage, with the
  rest rolled into "N others", for **Today**, **7 Days**, or **All** time. The card
  is a fixed height, because the menu's SwiftUI view is measured once when the
  menu is built and a growing card would be clipped.
- Preferences › **Apps** lists every app with its distance, clicks, and keystrokes.
- The focused app is cached from `NSWorkspace` activation notifications, never
  looked up per event, since crediting happens on every mouse move. No extra
  permission is needed.
- Apps are keyed by bundle ID, so the same app combines across Macs, with each
  Mac's days lined up on the local calendar by the same rule as the charts.
- Per-app data is included in each Mac's iCloud Drive file — which apps you use,
  in your own iCloud Drive. Files from before this existed still read fine.
- Resets clear the matching per-app metric too: Reset Mileage clears per-app
  distance, Reset Clicks per-app clicks, and so on.

## Auto-update

`UpdateController.swift` checks `https://api.github.com/repos/smanke/M3/releases/latest`,
compares the tag against the running `CFBundleShortVersionString`
(`AppInfo.version`, read straight from the bundle so it can't drift out of
sync with `Info.plist`), and if newer, downloads the release's `.dmg` asset.
Before installing anything it verifies the downloaded app: a valid signature,
the **same Developer ID Team ID** as the running app, and a passing Gatekeeper
assessment (i.e. Apple notarized it) — any failure aborts the update and
leaves the installed app untouched.

The same check runs a few seconds after launch when "Check for Updates at
Launch" is on (the menu bar toggle, or the checkbox in Preferences),
deliberately silent unless there is something to offer — reporting "up to
date", or a failed network call, on every single launch would be noise rather
than information. Declining an update offers "Skip This Version", which stops
the launch check raising that version again; checking manually still offers
it.

The swap itself is handed to a detached shell script, because an app cannot
replace and relaunch its own bundle while it is the one running: the script
waits for the process to exit, replaces the bundle, and reopens it. The old
bundle is moved aside rather than deleted, so a failed copy restores it
instead of leaving no app installed at all.

## Required permission

Keystroke counting requires **Accessibility** permission. On first launch
macOS prompts for it; it can also be granted at **System Settings → Privacy &
Security → Accessibility**.

The important wrinkle is that the permission is only needed for *keystrokes*.
A global event monitor receives mouse movement and clicks with no permission
at all, but `NSEvent` delivers key events only to an app that is trusted for
Accessibility — and when it isn't, those events simply never arrive, with no
error of any kind. The app therefore looks like it is working: mileage and
click counts climb normally while the keystroke count sits at zero forever.

Because that failure is invisible, `EventMonitor` tracks trust explicitly.
Preferences shows a warning with a button straight to the Accessibility
settings when the app isn't trusted, the state is logged at launch, and the
monitors are re-registered if trust is granted while the app is running —
a monitor registered before trust was granted does not start receiving key
events on its own.

## Running during development

```bash
M3_SYNC_FOLDER=/tmp/m3-sync swift run
```

`M3_SYNC_FOLDER` keeps a debug run from overwriting the installed app's iCloud
file. Tests cover chart merging across time zones and the sync-folder behavior:

```bash
swift test
```

## Building the .app

```bash
./build_app.sh
```

This builds a **universal binary** (`--arch arm64 --arch x86_64` — works
natively on both Intel and Apple Silicon Macs), assembles it into
`.build/app/M3 Tracker.app` with the app icon and Info.plist, and ad-hoc
code-signs it with a stable identifier (`com.smanke.MouseMileage`) so
Accessibility/Launch-at-Login permissions survive rebuilds. Deployment target
is macOS 13 (Ventura), which both Intel and Apple Silicon Macs can run.

Install and launch it with:

```bash
cp -R ".build/app/M3 Tracker.app" /Applications/
open "/Applications/M3 Tracker.app"
```

To survive reboots automatically, use the in-app "Launch at Login" checkbox
in Preferences (backed by `SMAppService.mainApp`, macOS 13+) once the app is
installed in `/Applications`, or add it manually as a Login Item in
**System Settings → General → Login Items**. `SMAppService` registration only
works from a properly installed `.app` bundle — running via `swift run` will
show a "couldn't update" alert if you try it.

Because counters are stored in `UserDefaults` under the app's bundle
identifier, keep the bundle identifier stable once you start using it —
changing it will reset the persisted history. Note that transferring the
`.app` bundle itself (e.g. via AirDrop or a zip) does **not** carry over
`~/Library/Preferences` — a fresh machine/user account starts with empty
counters, which is expected.

## Cutting a release

1. Bump `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist`
   (third component for ordinary changes, e.g. `1.13.1` → `1.13.2`).
2. `./release.sh "Developer ID Application: Your Name (TEAMID)"` — builds,
   signs, notarizes, and staples the `.app`.
3. `./make_dmg.sh` — wraps the stapled app into a signed, notarized
   `M3Tracker-<version>.dmg` at `.build/app/`.

The image opens as a 600x400 window with 128px icons, the app on the left and Applications
on the right. That layout ships as a captured `.DS_Store` (`Resources/dmg/DS_Store`) which
`make_dmg.sh` copies into the staging folder, rather than being applied by driving Finder
during a release; recapture it with `Tools/capture_dmg_layout.sh` if the window changes.
There is no background picture: on macOS 27 Finder shows one only while it is dropped into
the View Options picture well by hand and discards it when the window closes.
4. Create a GitHub release tagged `v<version>` (matching the plist version)
   at https://github.com/smanke/M3/releases/new and upload the `.dmg` as its
   asset. `UpdateController` fetches whatever asset ends in `.dmg` from the
   **latest** release, so this is the step that actually makes an update
   available to installed copies of the app.
