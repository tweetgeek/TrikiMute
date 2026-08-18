import Foundation

/// Confirms which physical device the user picked from the menu by counting
/// a random number of button presses within a time window.
///
/// The device's advertised name means nothing to a human holding it, so
/// selecting from a list isn't enough on its own — the user must also press
/// that specific device's button a set number of times to prove it's the
/// one they picked. Pure logic: timestamps are passed in by the caller
/// (from `ProcessInfo.processInfo.systemUptime`), never read from a clock
/// here, which keeps this fully unit-testable.
public struct PairingConfirmation {
    public enum Outcome: Equatable, Sendable {
        case pending(remaining: Int)
        case confirmed
        case timedOut
    }

    /// The range `randomRequirement()` draws from.
    public static let requiredRange: ClosedRange<Int> = 2...5

    /// Picks how many presses the user must make to confirm this pairing attempt.
    public static func randomRequirement() -> Int {
        Int.random(in: requiredRange)
    }

    public let required: Int

    private let deadline: TimeInterval
    private var pressCount = 0
    private var terminalOutcome: Outcome?

    public init(required: Int, timeout: TimeInterval, startedAt: TimeInterval) {
        self.required = required
        self.deadline = startedAt + timeout
    }

    /// Feeds one button event in. Only `.press` counts toward confirmation —
    /// `.hold` is treated like a `tick`: it reports where things stand
    /// without advancing or resetting the press count, so an accidental
    /// hold doesn't punish the user.
    public mutating func consume(_ event: ButtonEvent, at timestamp: TimeInterval) -> Outcome {
        guard event == .press else {
            return tick(at: timestamp)
        }
        if let outcome = terminalOutcome {
            return outcome
        }
        if timestamp >= deadline {
            return finish(.timedOut)
        }
        pressCount += 1
        return pressCount >= required ? finish(.confirmed) : .pending(remaining: required - pressCount)
    }

    /// Reports the current outcome for the given time without counting a press.
    /// Used to detect a timeout when no button event has arrived.
    public mutating func tick(at timestamp: TimeInterval) -> Outcome {
        if let outcome = terminalOutcome {
            return outcome
        }
        if timestamp >= deadline {
            return finish(.timedOut)
        }
        return .pending(remaining: required - pressCount)
    }

    private mutating func finish(_ outcome: Outcome) -> Outcome {
        terminalOutcome = outcome
        return outcome
    }
}
