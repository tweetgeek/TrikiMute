import AppKit
import TrikiMuteCore

/// Finds the Instances of supported browsers that are running right now.
///
/// The app no longer asks "which browsers do we know about, and which is
/// frontmost", but "which processes are there, and in what order should they
/// be searched".
enum RunningBrowsers {
    /// Reads `NSWorkspace`. Call on the main thread — `AppState` resolves this
    /// before handing work to the background script queue.
    @MainActor
    static func instances() -> [BrowserInstance] {
        instances(from: NSWorkspace.shared.runningApplications.map {
            ($0.bundleIdentifier, $0.processIdentifier, $0.isActive)
        })
    }

    /// The pure half, split out so it can be tested without a real workspace.
    static func instances(
        from running: [(bundleID: String?, pid: pid_t, isActive: Bool)]
    ) -> [BrowserInstance] {
        let supported = BrowserOrdering.supported
        let recognized = running.compactMap { app -> BrowserInstance? in
            guard let bundleID = app.bundleID,
                  let browser = supported.first(where: { $0.bundleID == bundleID })
            else { return nil }
            return BrowserInstance(pid: app.pid, browser: browser, isActive: app.isActive)
        }
        return BrowserOrdering.ordered(recognized, supported: supported)
    }
}
