import Foundation
import Testing
@testable import TrikiMuteCore

@Test func threePressesAtRequiredThreeYieldsConfirmedOnLast() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 2))
    #expect(c.consume(.press, at: 2) == .pending(remaining: 1))
    #expect(c.consume(.press, at: 3) == .confirmed)
}

@Test func holdDoesNotAdvanceOrResetTheCount() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 2))
    #expect(c.consume(.hold, at: 1.5) == .pending(remaining: 2))
    #expect(c.consume(.press, at: 2) == .pending(remaining: 1))
}

@Test func pressAfterTimeoutYieldsTimedOutRegardlessOfCount() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 2))
    #expect(c.consume(.press, at: 6) == .timedOut)
}

@Test func tickBeforeTimeoutWithNoPressesYieldsPendingWithFullRequirement() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.tick(at: 2) == .pending(remaining: 3))
}

@Test func tickAfterTimeoutYieldsTimedOut() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.tick(at: 6) == .timedOut)
}

@Test func callsAfterConfirmedStayConfirmedAndCounterDoesNotRegress() {
    var c = PairingConfirmation(required: 2, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 1))
    #expect(c.consume(.press, at: 2) == .confirmed)
    #expect(c.consume(.press, at: 3) == .confirmed)
    #expect(c.tick(at: 4) == .confirmed)
}

@Test func callsAfterTimedOutStayTimedOutEvenWithEnoughPresses() {
    var c = PairingConfirmation(required: 2, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 1))
    #expect(c.tick(at: 6) == .timedOut)
    #expect(c.consume(.press, at: 7) == .timedOut)
    #expect(c.consume(.press, at: 8) == .timedOut)
}

@Test func randomRequirementIsAlwaysWithinRequiredRangeAndCoversEveryValue() {
    // A constant implementation (e.g. always 2) would still pass a "within range"
    // check, which defeats the reason the requirement is random in the first place —
    // it lets a burst of accidental presses satisfy a predictable count. Over enough
    // draws, every value in the range must show up at least once.
    var draws: Set<Int> = []
    for _ in 0..<1000 {
        let value = PairingConfirmation.randomRequirement()
        #expect(PairingConfirmation.requiredRange.contains(value))
        draws.insert(value)
    }
    #expect(draws == Set(PairingConfirmation.requiredRange))
}

@Test func exactDeadlineInstantIsTimedOutForBothConsumeAndTick() {
    // consume and tick both use `timestamp >= deadline`. This pins that they agree at
    // the boundary itself, not just comfortably past it — an edit that flipped one path
    // to `>` while leaving the other at `>=` would otherwise slip through untested.
    var viaConsume = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(viaConsume.consume(.press, at: 5) == .timedOut)

    var viaTick = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(viaTick.tick(at: 5) == .timedOut)
}

@Test func holdAfterTimeoutYieldsTimedOut() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.consume(.hold, at: 6) == .timedOut)
}

@Test func tickAfterPartialPressesYieldsPendingWithRemainingCount() {
    var c = PairingConfirmation(required: 3, timeout: 5, startedAt: 0)
    #expect(c.consume(.press, at: 1) == .pending(remaining: 2))
    #expect(c.tick(at: 2) == .pending(remaining: 2))
}
