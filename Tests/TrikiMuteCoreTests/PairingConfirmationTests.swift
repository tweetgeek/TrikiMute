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

@Test func randomRequirementIsAlwaysWithinRequiredRange() {
    for _ in 0..<1000 {
        #expect(PairingConfirmation.requiredRange.contains(PairingConfirmation.randomRequirement()))
    }
}
