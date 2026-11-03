# M3 Tracker

Drive the app with `m3` (the app binary; `m3 help`). See `.claude/skills/m3/SKILL.md`. Commands live in
`Sources/MouseMileage/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which
starts a test copy on its own counts, settings (`com.smanke.MouseMileage.agenttest`) and sync folder (Release
builds ignore it). Find binaries with `swift build --show-bin-path`.
