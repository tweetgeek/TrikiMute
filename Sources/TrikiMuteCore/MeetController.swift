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
    ///
    /// On the way out, the fallback's `.noTarget` is discarded in favor of the
    /// primary's `.failed`. The two `.noTarget`s are not the same claim: from
    /// the primary it means "I searched every Instance and found no call";
    /// from the fallback, addressed by name, it means "I searched whichever
    /// Instance the system happened to route the Apple Event to" — a strictly
    /// weaker claim, and one already contradicted by the primary having been
    /// unable to finish. Only a positive answer from the fallback — a Target
    /// found — is trusted; anything else surfaces the primary's failure.
    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        let outcome = primary.probe(instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        let second = fallback.probe(instances: instances)
        if case .noTarget = second { return outcome }
        return second
    }

    /// Performs an Action in the first Instance that has a Target. Falls back
    /// under the same rule as `probe(instances:)`, and with the same caveat —
    /// the fallback cannot choose an Instance, so if a call is running in more
    /// than one, it may click in the wrong one (see `docs/follow-ups.md`).
    ///
    /// Same exit rule as `probe(instances:)`, and for the same reason: the
    /// fallback's `.noTarget` is a weaker claim than the primary's `.failed`,
    /// so it never overwrites it. Only `.performed` (or a fallback `.failed`,
    /// which replaces one failure with another) is trusted from the fallback.
    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        let outcome = primary.perform(action, instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        let second = fallback.perform(action, instances: instances)
        if case .noTarget = second { return outcome }
        return second
    }
}
