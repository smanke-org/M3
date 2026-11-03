import Foundation

/// Where M3 Tracker keeps its counts, history and settings: the app's own domain
/// (`com.smanke.MouseMileage`). A Debug test copy of the agent CLI (`APP_STORE=<folder>`)
/// gets a domain of its own instead, so it never reads or writes the real numbers.
/// Release builds always use the standard domain.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if AgentSocket.isTestRun, let suite = UserDefaults(suiteName: testSuiteName) { return suite }
        #endif
        return .standard
    }()

    /// The settings domain of a Debug agent CLI test copy. Delete it after testing:
    /// `defaults delete com.smanke.MouseMileage.agenttest`.
    static let testSuiteName = "com.smanke.MouseMileage.agenttest"
}
