---
name: m3
description: Read M3 Tracker, the mouse mileage app on this Mac, from the shell with the `m3` command: pointer distance, scrolling, clicks and keystrokes for this Mac and all the user's Macs, charts by hour and day, per-app totals, and mileage per mouse battery charge; also reset counters, rename a mouse, choose what the menu bar shows, and open the charts. Use when the user asks how far their mouse has gone, which apps they use the mouse in most, about mouse battery mileage, or names M3 Tracker.
---

# M3 Tracker

`m3` runs commands in the M3 Tracker app. Changes show in its menu at once. If the app is
closed, the command opens it in the background. If `m3` isn't on PATH, use
`"/Applications/M3 Tracker.app/Contents/MacOS/MouseMileage"` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Distances come as `distance` text (feet under a mile, then miles) and as `miles` numbers.
  "All Macs" combines every Mac syncing through iCloud Drive; `--this-mac` narrows to this one.
- `counters reset` and `mice reset` only report what they would reset. Show the user that
  report and ask before you run it again with `--yes`: neither can be undone, and a mouse's
  charge history is forgotten on every Mac.
- Find a mouse's id with `m3 mice list`; any unique start of it, or its name, works.
- To try something without real data, run a Debug build with `APP_STORE=/tmp/m3-test` in front.
  A test copy opens no windows.

## Main commands

| Command | Does |
| --- | --- |
| `m3 status --json` | Version, menu bar title, sync on or off and Mac count, keystroke permission |
| `m3 totals show --json` | This Mac and All Macs: distance, scrolling, clicks, keystrokes |
| `m3 history show [--chart today\|by-day\|year] [--this-mac] [--skip-empty] --json` | A chart's numbers per hour or day |
| `m3 apps list [--range today\|7days\|all] [--sort distance\|scroll\|clicks\|keystrokes\|name] [--limit N] --json` | Apps by distance |
| `m3 macs list --json` / `m3 mice list --json` | Each Mac's totals / each mouse's battery and miles per charge |
| `m3 counters reset <mileage\|scroll\|keystrokes\|clicks\|all> [--yes] --json` | Zero a counter on this Mac |

Everything else: `m3 help`, and `m3 help <command>` for its options.
