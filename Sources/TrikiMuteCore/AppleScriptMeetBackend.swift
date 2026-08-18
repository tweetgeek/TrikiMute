import Foundation

/// Reaches the Target the way the app did before Instances were understood:
/// by telling a browser, by name, to look through its own tabs.
///
/// Kept as the fallback path (ADR-0003), for the one failure the primary path
/// can have on its own — a change to the browser's scripting dictionary that
/// breaks the ScriptingBridge bindings. Its known weakness is exactly the
/// defect that motivated this work: a browser name cannot pick an Instance, so
/// when several are running, the system chooses for it.
public struct AppleScriptMeetBackend: MeetBackend {
    private let runner: any ScriptRunner

    public init(runner: any ScriptRunner) {
        self.runner = runner
    }

    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        var lastError: String?
        for browser in browserNames(instances) {
            let script = MeetScripts.appleScript(browser: browser, javascript: MeetScripts.probeJS())
            do {
                let response = try runner.run(script)
                guard response.count == 2 else { continue }
                let chars = Array(response)
                return .target(ProbeResult(
                    browser: browser,
                    micMuted: chars[0] == "1",
                    cameraOff: chars[1] == "1"
                ))
            } catch {
                lastError = error.localizedDescription
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        var lastError: String?
        for browser in browserNames(instances) {
            do {
                let response = try runner.run(
                    MeetScripts.appleScript(browser: browser, javascript: MeetScripts.toggleJS(action))
                )
                if response == "OK" { return .performed }
            } catch {
                lastError = error.localizedDescription
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    /// Browser names in the order their Instances appear, without repeats.
    /// Two Instances of one browser are a single question to AppleScript — it
    /// has no way to tell them apart, so asking twice would only cost time.
    private func browserNames(_ instances: [BrowserInstance]) -> [String] {
        var seen = Set<String>()
        return instances.compactMap { instance in
            seen.insert(instance.browser.name).inserted ? instance.browser.name : nil
        }
    }
}
