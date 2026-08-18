import CoreBluetooth
import Foundation
import Testing
@testable import TrikiMute

/// Fake `CentralManaging`: records what `TrikiConnection` actually asked of
/// `central`, without a real `CBCentralManager` or real Bluetooth hardware.
///
/// Doesn't (and can't) fake `CBPeripheral` — it has no public initializer —
/// so `retrievePeripheralsResult` defaults to empty and tests that would need
/// a real candidate or saved peripheral (`choose(_:)`, the persisted-identity
/// half of `confirmPairing()`, a completed `resumeSearch()`) stay out of this
/// file. See `CentralManaging`'s doc comment for the boundary this draws.
@MainActor
private final class FakeCentralManaging: CentralManaging {
    var state: CBManagerState
    private(set) var scanForPeripheralsCallCount = 0
    private(set) var stopScanCallCount = 0
    private(set) var connectCallCount = 0
    private(set) var cancelPeripheralConnectionCallCount = 0
    private(set) var retrievePeripheralsCallCount = 0
    var retrievePeripheralsResult: [CBPeripheral] = []

    init(state: CBManagerState) {
        self.state = state
    }

    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
        scanForPeripheralsCallCount += 1
    }
    func stopScan() { stopScanCallCount += 1 }
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?) { connectCallCount += 1 }
    func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancelPeripheralConnectionCallCount += 1 }
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral] {
        retrievePeripheralsCallCount += 1
        return retrievePeripheralsResult
    }
}

/// `TrikiConnection.knownDeviceKey` is `private` — this file can't see it
/// even via `@testable import` — so the literal is duplicated here,
/// deliberately, same as `FakeRunner` is duplicated between test targets
/// (see the comment in `AppStateTests.swift`). Tests that use this mutate
/// the real, process-wide `UserDefaults.standard`, because `TrikiConnection`
/// isn't written to take an injected store — so every use is scoped with
/// `withSavedDeviceIdentifier`, which always restores whatever was there
/// before, to avoid leaking state into the real app or other tests.
private let knownDeviceKey = "znanyKapselUUID"

@MainActor
private func withSavedDeviceIdentifier(_ uuid: UUID?, _ body: () -> Void) {
    let defaults = UserDefaults.standard
    let original = defaults.string(forKey: knownDeviceKey)
    if let uuid {
        defaults.set(uuid.uuidString, forKey: knownDeviceKey)
    } else {
        defaults.removeObject(forKey: knownDeviceKey)
    }
    defer {
        if let original {
            defaults.set(original, forKey: knownDeviceKey)
        } else {
            defaults.removeObject(forKey: knownDeviceKey)
        }
    }
    body()
}

// MARK: - Issue 1: startPairing() refusal

@Test @MainActor func startPairingRefusesWhenBluetoothIsNotPoweredOn() {
    let central = FakeCentralManaging(state: .poweredOff)
    let connection = TrikiConnection(central: central)

    let result = connection.startPairing()

    #expect(result == false)
    #expect(central.scanForPeripheralsCallCount == 0)
}

@Test @MainActor func startPairingScansWhenPoweredOnAndNoSessionLive() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)

    let result = connection.startPairing()

    #expect(result == true)
    #expect(central.scanForPeripheralsCallCount == 1)
}

@Test @MainActor func startPairingRefusesReentrantCallWhileSessionLive() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)

    #expect(connection.startPairing() == true)
    let second = connection.startPairing()

    #expect(second == false)
    // Only the first call actually asked `central` to scan.
    #expect(central.scanForPeripheralsCallCount == 1)
}

// MARK: - Issue 2: confirmPairing() requires an active session with a chosen candidate

@Test @MainActor func confirmPairingRefusesWithNoActiveSession() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)

    let result = connection.confirmPairing()

    #expect(result == false)
    #expect(central.stopScanCallCount == 0)
}

@Test @MainActor func confirmPairingRefusesWithNoChosenCandidate() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)
    // A session is live (still `.searching` in AppState terms), but
    // `choose(_:)` was never called — there is no `chosen` to persist.
    _ = connection.startPairing()

    let result = connection.confirmPairing()

    #expect(result == false)
    #expect(central.stopScanCallCount == 0)
}

// MARK: - cancelPairing(): scan-invariant defense, independent of call order

@Test @MainActor func cancelPairingIsANoOpWithNoActiveSession() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)

    connection.cancelPairing()

    #expect(central.stopScanCallCount == 0)
}

@Test @MainActor func cancelPairingStopsScanningWhileStillSearching() {
    let central = FakeCentralManaging(state: .poweredOn)
    let connection = TrikiConnection(central: central)
    _ = connection.startPairing()

    connection.cancelPairing()

    #expect(central.stopScanCallCount == 1)
    // Nothing was chosen, so there's no candidate connection to tear down.
    #expect(central.cancelPeripheralConnectionCallCount == 0)
}

// MARK: - Issue 3: a power-cycle can't hijack a live pairing session

/// The core of Issue 3 (final review): before the fix, `.poweredOn` called
/// `resumeSearch()` unconditionally, which — with a pairing session
/// live — would restart the saved-device resume (`retrievePeripherals`,
/// then a pending `connect()`) instead of the scan, hijacking whatever the
/// session was doing. This pins that a live session gets the scan restarted
/// and the saved device is never even looked at.
@Test @MainActor func poweredOnRestartsTheScanInsteadOfResumingSavedDeviceDuringPairing() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        _ = connection.startPairing()
        #expect(central.scanForPeripheralsCallCount == 1)

        // Simulates a Bluetooth power-cycle mid-pairing: the delegate
        // reports .poweredOn again while `pairing` is still live.
        connection.handleCentralStateChange(.poweredOn)

        #expect(central.scanForPeripheralsCallCount == 2)
        #expect(central.retrievePeripheralsCallCount == 0)
        #expect(central.connectCallCount == 0)
    }
}

/// Regression pin for the constraint that matters most: the saved-device
/// daily path (no pairing session live) must be completely unaffected by the
/// Issue 3 guard. Without a session, `.poweredOn` still resumes the saved
/// device exactly as before.
@Test @MainActor func poweredOnResumesSavedDeviceWhenNoPairingSessionIsLive() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        // No startPairing() call — `pairing` is nil, matching the daily path.

        connection.handleCentralStateChange(.poweredOn)

        #expect(central.retrievePeripheralsCallCount == 1)
        #expect(central.scanForPeripheralsCallCount == 0)
    }
}

@Test @MainActor func poweredOnDoesNothingWithNoSavedDeviceAndNoPairingSession() {
    withSavedDeviceIdentifier(nil) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.handleCentralStateChange(.poweredOn)

        #expect(central.retrievePeripheralsCallCount == 0)
        #expect(central.scanForPeripheralsCallCount == 0)
        #expect(central.connectCallCount == 0)
    }
}

// MARK: - forget(): restores the saved-but-unreachable capsule's recovery route

/// The plain case: a saved identifier, no session live. `forget()` must
/// clear it — `hasSavedDevice` is the property the menu (and this test)
/// reads to decide whether "Zapomnij Kapsel" is even shown.
@Test @MainActor func forgetClearsTheSavedIdentifier() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        #expect(connection.hasSavedDevice)

        connection.forget()

        #expect(!connection.hasSavedDevice)
    }
}

/// The hardened half (recovered from before `forget()` was deleted as dead
/// code): a pairing session in progress must not survive `forget()` — the
/// scan invariant belongs to `TrikiConnection` regardless of what phase
/// pairing was in, not merely because a well-behaved caller is expected to
/// stop pairing first. Stopping the scan here is what a caller could
/// otherwise skip and leave running with nothing left able to stop it.
@Test @MainActor func forgetStopsAnyInProgressPairingScan() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        #expect(connection.startPairing() == true)
        #expect(central.scanForPeripheralsCallCount == 1)

        connection.forget()

        #expect(central.stopScanCallCount == 1)
        // The session is gone, not just the scan — startPairing() must be
        // able to start a fresh one immediately, not be refused as
        // reentrant against a session forget() should have already ended.
        #expect(connection.startPairing() == true)
        #expect(central.scanForPeripheralsCallCount == 2)
    }
}

/// The behavioral decision at the center of restoring this method: after
/// forgetting, the app must sit idle rather than immediately go hunting for
/// the very device it was just told to forget. `forget()` clears the saved
/// identifier before calling `resumeSearch()`, so `resumeSearch()` finds
/// nothing saved and does nothing — no retrieval, no pending connect.
@Test @MainActor func forgetLeavesTheAppIdleInsteadOfResumingSearchForTheForgottenDevice() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.forget()

        #expect(central.retrievePeripheralsCallCount == 0)
        #expect(central.connectCallCount == 0)
    }
}

/// Forgetting with nothing saved and no session live must not misbehave —
/// no scan to stop, no identifier to clear beyond a no-op removal, no
/// resumeSearch side effect.
@Test @MainActor func forgetWithNothingSavedAndNoSessionIsHarmless() {
    withSavedDeviceIdentifier(nil) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.forget()

        #expect(!connection.hasSavedDevice)
        #expect(central.stopScanCallCount == 0)
        #expect(central.retrievePeripheralsCallCount == 0)
    }
}

// MARK: - Sleep wait: `startSleepWait()`/`beginSleepWaitBurst()`/`endSleepWaitBurst()`/
// `checkSleepWaitCapDeadline()`, driven directly the same way
// `handleCentralStateChange(_:)` is — no real `CBPeripheral` needed, since
// the wait is keyed off the saved identifier read fresh from `UserDefaults`,
// not off `peripheral`. See `TrikiConnection`'s "Sleep wait" section and
// `SleepWait` (the pure decision logic, tested on its own in
// `SleepWaitTests`) for the design this pins the orchestration of.

/// `startSleepWait()` alone (before any burst outcome) must not re-arm the
/// pending connect — `retrievePeripheralsCallCount` is this file's
/// established proxy for "resumeSearch() attempted a reconnect" (see
/// `poweredOnResumesSavedDeviceWhenNoPairingSessionIsLive` above), used
/// throughout this section for the same reason: `FakeCentralManaging` can't
/// produce a real `CBPeripheral`, so a completed reconnect can't be
/// asserted directly, but the attempt to look one up can be.
@Test @MainActor func startingTheWaitAloneDoesNotYetIssueThePendingConnect() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()

        #expect(central.retrievePeripheralsCallCount == 0)
        // A burst is scanning, exactly as the short-burst design calls for.
        #expect(central.scanForPeripheralsCallCount == 1)
    }
}

/// The device is sighted during the first burst — genuinely still
/// advertising — so ending that burst must not conclude the wait, and the
/// next burst (simulating the gap timer elapsing in production) must still
/// be reachable — the wait didn't get stuck refusing to scan again.
@Test @MainActor func devicePresentDuringABurstDoesNotIssueThePendingConnect() {
    let savedID = UUID()
    withSavedDeviceIdentifier(savedID) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        connection.handleSleepWaitSighting(identifier: savedID)
        connection.endSleepWaitBurst()

        #expect(central.retrievePeripheralsCallCount == 0)
        // Paused for the gap between bursts — not still scanning, and not
        // concluded either.
        #expect(central.scanForPeripheralsCallCount == 1)
        #expect(central.stopScanCallCount == 1)

        // The next burst (the gap timer, driven directly).
        connection.beginSleepWaitBurst()
        #expect(central.scanForPeripheralsCallCount == 2)
        #expect(central.retrievePeripheralsCallCount == 0)
    }
}

/// A sighting of a *different* device's identifier must not stand in for
/// the saved one — "match the saved identifier specifically."
@Test @MainActor func sightingOfADifferentDeviceDuringABurstStillConcludesDeviceIsGone() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        connection.handleSleepWaitSighting(identifier: UUID())  // some other capsule
        connection.endSleepWaitBurst()

        #expect(central.retrievePeripheralsCallCount == 1)
    }
}

/// The plain success case: a burst ends without ever sighting the saved
/// identifier — the device is presumed asleep, and the pending connect is
/// re-armed via the same `resumeSearch()` an ordinary reconnect uses.
@Test @MainActor func burstEndingWithNoSightingIssuesThePendingConnect() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        connection.endSleepWaitBurst()

        #expect(central.retrievePeripheralsCallCount == 1)
        // Concluded: scanning stopped for good, not moved to a next burst.
        #expect(central.stopScanCallCount == 1)
    }
}

/// The cap fires while the device is still being sighted every burst — the
/// case a button press produces, since a press keeps the Kapsel awake and
/// advertising the whole time (see `SleepWait`'s doc on this being a
/// feature, not a gap). The cap must still re-arm the pending connect
/// rather than wait forever.
@Test @MainActor func capFiringWhileDeviceIsStillPresentStillIssuesThePendingConnect() {
    let savedID = UUID()
    withSavedDeviceIdentifier(savedID) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        // Several bursts in a row, each one sighting the device — it never
        // goes quiet on its own.
        for _ in 0..<5 {
            connection.handleSleepWaitSighting(identifier: savedID)
            connection.endSleepWaitBurst()
        }
        #expect(central.retrievePeripheralsCallCount == 0)  // still genuinely waiting

        connection.checkSleepWaitCapDeadline()

        #expect(central.retrievePeripheralsCallCount == 1)
    }
}

/// The cap must also work as a bound with no bursts having run at all —
/// belt and suspenders against a burst timer somehow never firing.
@Test @MainActor func capFiringWithNoBurstEverHavingConcludedStillIssuesThePendingConnect() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        connection.checkSleepWaitCapDeadline()

        #expect(central.retrievePeripheralsCallCount == 1)
    }
}

/// Once concluded, further ticks must be no-ops — the wait already handed
/// off to `resumeSearch()` once; a stray extra `endSleepWaitBurst()` or
/// `checkSleepWaitCapDeadline()` call (e.g. a race between the two real
/// Timers in production) must not issue a second, redundant reconnect
/// attempt.
@Test @MainActor func onceConcludedFurtherTicksDoNotIssueASecondPendingConnect() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)

        connection.startSleepWait()
        connection.endSleepWaitBurst()
        #expect(central.retrievePeripheralsCallCount == 1)

        connection.checkSleepWaitCapDeadline()
        connection.endSleepWaitBurst()

        #expect(central.retrievePeripheralsCallCount == 1)
    }
}

/// Starting a fresh pairing session while the wait is live must cancel it
/// cleanly: no stray reconnect can land underneath the candidate the user
/// is now choosing between, and `startPairing()` must not be refused as if
/// a session were somehow already active.
@Test @MainActor func startingPairingDuringTheWaitCancelsIt() {
    let savedID = UUID()
    withSavedDeviceIdentifier(savedID) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        connection.startSleepWait()
        #expect(central.scanForPeripheralsCallCount == 1)  // the wait's own first burst

        let result = connection.startPairing()

        #expect(result == true)
        // Pairing's own scan started — the cancelled wait didn't block it.
        #expect(central.scanForPeripheralsCallCount == 2)

        // The cancelled wait must not still be listening: a sighting or a
        // burst/cap tick arriving late must not reconnect anything out from
        // under the pairing session now in progress.
        connection.handleSleepWaitSighting(identifier: savedID)
        connection.endSleepWaitBurst()
        connection.checkSleepWaitCapDeadline()
        #expect(central.retrievePeripheralsCallCount == 0)
    }
}

/// Forgetting the device while the wait is live must cancel it the same
/// way — otherwise a burst concluding after `forget()` would call
/// `resumeSearch()`, which (harmlessly, since the identifier is already
/// cleared) would find nothing — but the scan invariant and timers must
/// still be torn down here, not left to that accidental safety net.
@Test @MainActor func forgettingDuringTheWaitCancelsIt() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        connection.startSleepWait()
        #expect(central.scanForPeripheralsCallCount == 1)

        connection.forget()

        #expect(!connection.hasSavedDevice)
        // The cancelled wait's scan was stopped as part of tearing it down
        // (forget() also stops any pairing scan, but no pairing was active
        // here — this stopScan() call can only be the wait's).
        #expect(central.stopScanCallCount == 1)

        // A late burst conclusion must not resurrect a connection attempt
        // for the identifier `forget()` just cleared.
        connection.endSleepWaitBurst()
        connection.checkSleepWaitCapDeadline()
        #expect(central.retrievePeripheralsCallCount == 0)
    }
}

/// A Bluetooth power cycle mid-wait must resume the interrupted burst
/// rather than fall through to `resumeSearch()` — the same "don't let an
/// unrelated event re-arm the pending connect early" posture as the
/// pairing/forget cancellation tests above, but for the case where nothing
/// actually asked to leave the wait.
@Test @MainActor func poweredOnDuringTheWaitResumesTheBurstInsteadOfResumingSavedDevice() {
    withSavedDeviceIdentifier(UUID()) {
        let central = FakeCentralManaging(state: .poweredOn)
        let connection = TrikiConnection(central: central)
        connection.startSleepWait()
        #expect(central.scanForPeripheralsCallCount == 1)

        connection.handleCentralStateChange(.poweredOn)

        #expect(central.scanForPeripheralsCallCount == 2)
        #expect(central.retrievePeripheralsCallCount == 0)
    }
}
