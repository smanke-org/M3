import AppKit

// `m3 <command>` (the app binary under a short name): run it against the running app and
// exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
