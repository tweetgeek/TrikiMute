import Foundation

/// Recognizes Presses and Holds from a stream of button states.
///
/// The device transmits the button's *level* on every frame (~104 Hz), not
/// events, so recognition works by detecting edges. A Hold is reported the
/// moment the threshold is crossed, not on release — so feedback arrives
/// immediately, without waiting for you to lift your finger.
public struct ButtonRecognizer {
    /// Recognition time constants. All in seconds.
    public struct Tuning: Sendable {
        public let hold: TimeInterval
        public let debounce: TimeInterval
        public let cooldown: TimeInterval

        public init(hold: TimeInterval, debounce: TimeInterval, cooldown: TimeInterval) {
            self.hold = hold
            self.debounce = debounce
            self.cooldown = cooldown
        }

        public static let standard = Tuning(hold: 0.4, debounce: 0.03, cooldown: 0.3)
    }

    private let tuning: Tuning
    private var isPressed = false
    private var pressStart: TimeInterval = 0
    private var holdReported = false
    private var lastEdge: TimeInterval = -.greatestFiniteMagnitude
    private var lastEvent: TimeInterval = -.greatestFiniteMagnitude

    public init(tuning: Tuning = .standard) {
        self.tuning = tuning
    }

    /// Returns an event if this sample completes one.
    public mutating func consume(_ sample: ButtonSample) -> ButtonEvent? {
        if sample.pressed != isPressed {
            guard sample.timestamp - lastEdge >= tuning.debounce else {
                return nil  // contact bounce
            }
            lastEdge = sample.timestamp
            isPressed = sample.pressed

            if isPressed {
                pressStart = sample.timestamp
                holdReported = false
                return nil
            }
            // Release. Hold already reported — don't duplicate the event.
            guard !holdReported else { return nil }
            guard sample.timestamp - pressStart < tuning.hold else { return nil }
            return emit(.press, at: sample.timestamp)
        }

        guard isPressed, !holdReported else { return nil }
        guard sample.timestamp - pressStart >= tuning.hold else { return nil }
        // The flag is only set after the event is actually emitted. If it were
        // set earlier, a Hold suppressed by the cooldown would be lost for
        // good instead of arriving later.
        guard let event = emit(.hold, at: sample.timestamp) else { return nil }
        holdReported = true
        return event
    }

    private mutating func emit(_ event: ButtonEvent, at timestamp: TimeInterval) -> ButtonEvent? {
        guard timestamp - lastEvent >= tuning.cooldown else { return nil }
        lastEvent = timestamp
        return event
    }
}
