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
///
/// A facade over two backends. The primary one addresses Instances by process
/// and is the reason this type stopped talking to AppleScript directly; the
/// fallback is the old name-addressed path, kept for a failure only the primary
/// can have (see ADR-0003).
public struct MeetController {
    private let primary: any MeetBackend
    private let fallback: (any MeetBackend)?

    public init(primary: any MeetBackend, fallback: (any MeetBackend)? = nil) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Looks for the Target across the given Instances.
    ///
    /// The fallback runs on `.failed` and on nothing else. `.noTarget` means the
    /// primary path already searched every Instance and found no call — the
    /// fallback searches a subset of the same browsers, so it cannot find
    /// anything the primary missed, and asking it would add an Apple Event per
    /// browser to every probe tick in the app's most common state.
    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        let outcome = primary.probe(instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        return fallback.probe(instances: instances)
    }

    /// Performs an Action in the first Instance that has a Target. Falls back
    /// under the same rule as `probe(instances:)`, and with the same caveat —
    /// the fallback cannot choose an Instance, so if a call is running in more
    /// than one, it may click in the wrong one (see `docs/follow-ups.md`).
    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        let outcome = primary.perform(action, instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        return fallback.perform(action, instances: instances)
    }
}

extension MeetController {
    /// Temporary bridge for call sites still written against the old shape,
    /// removed in the task that migrates `AppState`. Exists so that every
    /// commit on this branch builds — a broken intermediate commit would
    /// make `git bisect` useless across exactly the range where the risky
    /// change lands.
    @available(*, deprecated, message: "Przejdź na MeetController(primary:fallback:)")
    public init(runner: any ScriptRunner) {
        self.init(primary: AppleScriptMeetBackend(runner: runner), fallback: nil)
    }
}
