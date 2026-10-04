# M3 Tracker: Mac Mouse Mileage Tracker

**Shows how far your mouse really travels, plus your clicks, keystrokes and scrolling, on every Mac you use.**

You move a mouse or trackpad all day without any sense of how much. M3 Tracker is a small menu
bar app that turns that into a number you can see: feet, then miles, of pointer travel. It
also counts clicks and keystrokes and how far content scrolls, with charts by hour, day and
year, a breakdown by app, and combined totals across all your Macs through iCloud Drive.
It's a fun way to see your habits, and a useful one: you might find which app keeps your
hand moving the most, or how far a mouse goes on one battery charge.

---

## ⬇️ Download

<p align="center">
  <a href="https://github.com/smanke-org/M3/releases/latest/download/M3Tracker.dmg">
    <img src="https://img.shields.io/badge/Download-M3Tracker.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download M3Tracker.dmg" height="48">
  </a>
</p>

1. **[Download M3Tracker.dmg](https://github.com/smanke-org/M3/releases/latest/download/M3Tracker.dmg)**
2. Open it and drag **M3 Tracker** to **Applications**.
3. Open M3 Tracker. The distance appears in the menu bar right away.
4. Grant **Accessibility** when macOS asks (System Settings › Privacy & Security ›
   Accessibility). Mileage and clicks work without it, but keystrokes are only counted with
   it. See [Required permission](#required-permission).

Requires macOS 13 or later, Intel or Apple silicon. Signed with Developer ID and notarized by Apple.

---

## Updates

M3 Tracker checks GitHub for a new release a few seconds after launch, and stays silent unless
there is one. You can also choose **Check for Updates…** from the menu bar dropdown at any time.
Nothing installs until you confirm it. Before installing, the download must be signed by the
same developer and notarized by Apple. See [Auto-update](#auto-update) for details.

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
  `SMAppService` (`LaunchAtLoginController.swift`), plus "Show in Dock" (off
  by default) and "Show in menu bar" (on) checkboxes, in any combination
  (`AppPresence.swift`). The Dock icon's right-click menu offers Preferences…;
  with both off, opening the app again from Applications opens Preferences.

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

## Scrolling

The app also measures **how far content scrolls**: pages, documents, lists. It's
kept separate from pointer mileage and never added into it.

- A trackpad or Magic Mouse reports scrolling in points. A notched wheel reports
  lines, but macOS also attaches the points it actually scrolled for them
  (`scrollWheelEventPointDeltaAxis1/2`, with acceleration), and that's what's
  counted. 1.15.9–1.15.11 counted 10 pt per line, which undercounted wheel
  scrolling. The glide after a flick counts too, since the content keeps moving.
- Scrolling is credited to the app **under the pointer**, since that's the
  window that scrolls, even when it isn't the frontmost app. The app is looked
  up once at the start of each scroll gesture.
- It shows as **Scrolled This Mac** and **Scrolled All Macs** rows in the menu
  totals, under **Moved This Mac** and **Moved All Macs**, a second **orange line on every chart**, a sortable **Scroll**
  column in Preferences › Apps, and a line in Preferences › General with its own
  reset. It syncs across Macs like everything else.

## Troubleshooting another Mac

Each Mac's iCloud Drive file (`M3 Tracker/Devices/<id>.json`) includes a
`diagnostics` section: app version, launch time, whether Accessibility is
granted, scroll events since launch split into trackpad and wheel, the lines
and points behind the wheel events, the last scroll time, and the battery
tracker's status and recent events. So a problem on one Mac can be looked into
from any other.

## Menu layout

Click any chart (Today by Hour, By Day, Year to Date) in the menu or the flyout
to open it in a **resizable window**, where it fills the space. Pointing at the
chart there shows that hour's, day's or month's pointer and scroll distance. The
window switches between the three charts and keeps updating while it's open.

The dropdown always starts with the This Mac / All Macs totals. Beneath them,
each card (Top Apps, Mileage per Charge, Today by Hour, By Day and Year to Date)
can go in the menu, in the **More Charts ▸** flyout, in both, or in neither.
They're set in Preferences › **Menu**. By default the menu holds only Today by
Hour and the flyout holds everything, so the menu fits a laptop screen without
scrolling. The flyout lays out four or more cards in two columns. Both views are
measured when they're built, so they are rebuilt whenever the choice changes.

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

## Mileage per battery charge

An optional tracker, off until turned on in Preferences › **Battery**, for how far
a mouse travels on one charge, and whether that is rising or falling over time.
It is kept apart from the main mileage and the per-app numbers: its reset touches
nothing else, and theirs don't touch it.

- **Supported mice:** Logitech mice over Bluetooth, Bolt, or Unifying, and Apple
  Magic Mouse. Logitech batteries are read over HID++ (feature 0x1004, or 0x1000
  on older mice), the way Logi Options+ reads them. macOS itself doesn't know an
  MX Master's battery level. A Magic Mouse's level is read from the I/O Registry.
  The Bluetooth path is verified with an MX Master 4. The receiver path follows
  the same protocol but hasn't been tested on real hardware, and neither has
  Magic Mouse.
- **Only the mouse counts, not the trackpad.** The app watches each mouse's own
  motion reports and credits a pointer move to a mouse only if it reported motion
  in the last 100 ms. The distance uses the same units as the main mileage.
- **Charges are derived from battery readings.** A charge ends at the first
  reading that shows the mouse charging, or that has risen 10 or more points
  above its lowest level (a recharge the app didn't see). The next charge starts
  when the mouse is unplugged. Movement while on the cable belongs to no charge.
- **Miles per full charge** is miles ÷ battery used × 100, so charges compare
  fairly however low the battery ran. It appears once a charge has used 10%.
- **Across Macs:** the mouse is identified by its serial number, so an
  Easy-Switch mouse is one mouse on every Mac. Each Mac syncs its readings and
  hourly movement for the mouse in its iCloud Drive file, and charges are worked
  out from all of them together.
- **Low-battery warning:** when a tracked mouse drops below 5% (or reports
  itself critical, since some mice report their level in coarse steps), a notice
  appears in the top-right corner naming its make and model, for example
  "Logitech MX Master 4". It's a floating card in the style of NetworkToggle's
  panel: it doesn't take focus, and a click anywhere on it dismisses it. It's
  shown once per discharge and comes back only after the mouse has been charged.
  It can be turned off, or previewed, in Preferences › Battery.
- The menu gets a **Mileage per Charge** card, and Preferences › **Battery** has
  the chart and the list of charges.
- **Telling identical mice apart:** click the pencil next to a mouse's name in
  Preferences › Battery to rename it. The name syncs to all your Macs. Until
  it's renamed, a mouse that shares its model name with another gets the end
  of its serial number, as in "MX Master 4 · BR48". The serial is printed
  under the mouse.
- A Logitech mouse is keyed on its unit ID, which is always read when it
  connects. Versions 1.15.0–1.15.4 used the serial number when that separate
  read succeeded, so one failed read split a mouse in two. The old key is
  kept as an alias, so those histories and older Macs' files merge back in.

## Auto-update

`UpdateController.swift` checks `https://api.github.com/repos/smanke-org/M3/releases/latest`,
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

**Input Monitoring** is needed only for mileage per battery charge, and is only
requested when that is turned on. Opening a mouse's HID device (to read its
battery, and its motion) fails with `kIOReturnNotPermitted` without it. macOS
may apply a new grant only after the app relaunches, and Preferences says so
when that happens.

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
   `M3Tracker-<version>.dmg` at `.build/app/`, plus an identical `M3Tracker.dmg`.

The image opens as a 600x400 window with 128px icons, the app on the left and Applications
on the right. That layout ships as a captured `.DS_Store` (`Resources/dmg/DS_Store`) which
`make_dmg.sh` copies into the staging folder, rather than being applied by driving Finder
during a release; recapture it with `Tools/capture_dmg_layout.sh` if the window changes.
There is no background picture: on macOS 27 Finder shows one only while it is dropped into
the View Options picture well by hand and discards it when the window closes.
4. Create a GitHub release tagged `v<version>` (matching the plist version)
   at https://github.com/smanke-org/M3/releases/new and upload **both** `.dmg` files.
   The README's download button points at `releases/latest/download/M3Tracker.dmg`,
   which only resolves if every release carries a file with exactly that name. `UpdateController` fetches whatever asset ends in `.dmg` from the
   **latest** release, so this is the step that actually makes an update
   available to installed copies of the app.
