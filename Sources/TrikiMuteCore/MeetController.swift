import Foundation

/// Executor for scripts. The production implementation wraps `NSAppleScript`,
/// the test one returns programmed responses.
public protocol ScriptRunner {
    func run(_ source: String) throws -> String
}

/// Where the Target is and what state it's in.
public struct ProbeResult: Equatable, Sendable {
    public let browser: String
    public let micMuted: Bool
    public let cameraOff: Bool

    public init(browser: String, micMuted: Bool, cameraOff: Bool) {
        self.browser = browser
        self.micMuted = micMuted
        self.cameraOff = cameraOff
    }
}

/// Result of an Action. The distinction between `noTarget` and `failed` is
/// deliberate: the first means "there's nothing to mute", the second means
/// "I had something to do and it didn't work".
public enum ActionOutcome: Equatable, Sendable {
    case performed
    case noTarget
    case failed(String)
}

/// Result of a probe. Same distinction as in `ActionOutcome`, for the same
/// reason: if a failure were reported as "no target", the menu bar would
/// claim everything is fine while Automation access had actually been
/// revoked, or JavaScript execution disabled in the browser.
public enum ProbeOutcome: Equatable, Sendable {
    case target(ProbeResult)
    case noTarget
    case failed(String)
}

/// Controls the microphone and camera in the Target.
public struct MeetController {
    private let runner: ScriptRunner

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    /// Looks for the Target in the given browsers, in order. Returns the
    /// state of the first tab that has a full set of buttons; if none has a
    /// Target, distinguishes "no call anywhere" from "couldn't check".
    public func probe(browsers: [String]) -> ProbeOutcome {
        var lastError: String?
        for browser in browsers {
            let script = MeetScripts.appleScript(
                browser: browser,
                javascript: MeetScripts.probeJS()
            )
            do {
                let response = try runner.run(script)
                // The "NONE" sentinel is four characters long, so it's
                // naturally excluded here.
                guard response.count == 2 else { continue }
                let chars = Array(response)
                return .target(ProbeResult(
                    browser: browser,
                    micMuted: chars[0] == "1",
                    cameraOff: chars[1] == "1"
                ))
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    /// Performs an Action in the first browser that has a Target.
    public func perform(_ action: MeetAction, browsers: [String]) -> ActionOutcome {
        var lastError: String?
        for browser in browsers {
            do {
                let response = try runner.run(
                    MeetScripts.appleScript(browser: browser, javascript: MeetScripts.toggleJS(action))
                )
                if response == "OK" { return .performed }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }
}
