import Foundation
import Testing
@testable import TrikiMuteCore

private let watched = UUID()
private let other = UUID()

@Test func burstEndingWithoutASightingConcludesDeviceIsGone() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.burstEnded()
    #expect(wait.outcome == .deviceIsGone)
}

@Test func sightingDuringTheBurstKeepsWaiting() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.sighted(watched)
    wait.burstEnded()
    #expect(wait.outcome == nil)
}

/// A different capsule advertising nearby must not stand in for the one
/// actually being watched — only the saved identifier counts.
@Test func sightingOfADifferentIdentifierDoesNotCountAsPresence() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.sighted(other)
    wait.burstEnded()
    #expect(wait.outcome == .deviceIsGone)
}

/// A sighting from a previous burst must not leak into the next one —
/// `burstStarted()` is what clears it, not `burstEnded()`'s own bookkeeping
/// alone. This pins that the caller is expected to call it at the start of
/// every burst, not just the first.
@Test func sightingInOneBurstDoesNotCarryOverToTheNextBurst() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.sighted(watched)
    wait.burstEnded()
    #expect(wait.outcome == nil)  // still waiting after burst 1 (device was seen)

    wait.burstStarted()
    // No sighting this time.
    wait.burstEnded()
    #expect(wait.outcome == .deviceIsGone)
}

@Test func capElapsingWithNoSightingHistoryConcludesCapExpired() {
    var wait = SleepWait(identifier: watched)
    wait.capElapsed()
    #expect(wait.outcome == .capExpired)
}

/// The pleasant second meaning of the cap: a press during the wait keeps
/// the device awake and advertising, so it's sighted every burst and never
/// reaches `.deviceIsGone` on its own — only the cap concludes it, arming
/// the app anyway.
@Test func capElapsingMidBurstWithTheDeviceStillPresentConcludesCapExpiredNotDeviceIsGone() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.sighted(watched)
    wait.capElapsed()
    #expect(wait.outcome == .capExpired)
}

/// First conclusion wins — nothing here regresses an outcome once reached.
@Test func onceConcludedFurtherEventsDoNotChangeTheOutcome() {
    var wait = SleepWait(identifier: watched)
    wait.burstStarted()
    wait.burstEnded()
    #expect(wait.outcome == .deviceIsGone)

    // A late cap firing, a late sighting, another burst — all no-ops.
    wait.capElapsed()
    #expect(wait.outcome == .deviceIsGone)
    wait.sighted(watched)
    wait.burstStarted()
    wait.burstEnded()
    #expect(wait.outcome == .deviceIsGone)
}

/// Same idempotency, the other direction: once the cap has concluded things,
/// a subsequent burst ending without a sighting must not later "downgrade"
/// the recorded outcome away from `.capExpired`.
@Test func onceCapExpiredALaterEmptyBurstDoesNotOverwriteTheOutcome() {
    var wait = SleepWait(identifier: watched)
    wait.capElapsed()
    #expect(wait.outcome == .capExpired)

    wait.burstStarted()
    wait.burstEnded()
    #expect(wait.outcome == .capExpired)
}
