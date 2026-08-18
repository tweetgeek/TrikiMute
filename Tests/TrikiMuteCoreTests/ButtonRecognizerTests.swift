import Foundation
import Testing
@testable import TrikiMuteCore

/// Feeds the recognizer a sequence of samples every 10 ms and returns all events.
private func replay(
    _ recognizer: inout ButtonRecognizer,
    pressed: Bool,
    for duration: TimeInterval,
    from start: TimeInterval
) -> [ButtonEvent] {
    var events: [ButtonEvent] = []
    var t = start
    while t < start + duration {
        if let e = recognizer.consume(ButtonSample(pressed: pressed, timestamp: t)) {
            events.append(e)
        }
        t += 0.01
    }
    return events
}

@Test func shortPressYieldsPress() {
    var r = ButtonRecognizer()
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    _ = replay(&r, pressed: true, for: 0.3, from: 0.2)
    let after = replay(&r, pressed: false, for: 0.2, from: 0.5)
    #expect(after == [.press])
}

@Test func holdFiresAtThresholdCrossing() {
    var r = ButtonRecognizer()
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    let during = replay(&r, pressed: true, for: 1.5, from: 0.2)
    #expect(during == [.hold])
}

@Test func releaseAfterHoldYieldsNoPress() {
    var r = ButtonRecognizer()
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    _ = replay(&r, pressed: true, for: 1.5, from: 0.2)
    let after = replay(&r, pressed: false, for: 0.5, from: 1.7)
    #expect(after.isEmpty)
}

@Test func justBelowThresholdIsPress() {
    var r = ButtonRecognizer(tuning: .init(hold: 0.4, debounce: 0.03, cooldown: 0.0))
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    let during = replay(&r, pressed: true, for: 0.35, from: 0.2)
    #expect(during.isEmpty)
    let after = replay(&r, pressed: false, for: 0.2, from: 0.55)
    #expect(after == [.press])
}

@Test func contactBounceIsSuppressed() {
    var r = ButtonRecognizer()
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    // Three edges within 20 ms — below the debounce threshold.
    var events: [ButtonEvent] = []
    for (i, state) in [true, false, true].enumerated() {
        if let e = r.consume(ButtonSample(pressed: state, timestamp: 0.2 + Double(i) * 0.005)) {
            events.append(e)
        }
    }
    #expect(events.isEmpty)
}

@Test func cooldownSuppressesSecondPress() {
    var r = ButtonRecognizer()
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    _ = replay(&r, pressed: true, for: 0.2, from: 0.2)
    let first = replay(&r, pressed: false, for: 0.1, from: 0.4)
    #expect(first == [.press])
    _ = replay(&r, pressed: true, for: 0.1, from: 0.5)
    let second = replay(&r, pressed: false, for: 0.1, from: 0.6)
    #expect(second.isEmpty)
}

@Test func holdSuppressedByCooldownArrivesLater() {
    // Pathological configuration: cooldown longer than debounce + threshold.
    // Without the fix, the holdReported flag would still get set despite the
    // suppression, and the Hold would be lost for good.
    var r = ButtonRecognizer(tuning: .init(hold: 0.4, debounce: 0.03, cooldown: 0.8))
    _ = replay(&r, pressed: false, for: 0.2, from: 0.0)
    _ = replay(&r, pressed: true, for: 0.2, from: 0.2)
    let first = replay(&r, pressed: false, for: 0.1, from: 0.4)
    #expect(first == [.press])
    // The threshold passes at 0.9 s, but the cooldown after the Press lasts until 1.2 s.
    let during = replay(&r, pressed: true, for: 1.2, from: 0.5)
    #expect(during == [.hold])
}

@Test func steadyReleasedStateYieldsNoEvents() {
    var r = ButtonRecognizer()
    let events = replay(&r, pressed: false, for: 5.0, from: 0.0)
    #expect(events.isEmpty)
}
