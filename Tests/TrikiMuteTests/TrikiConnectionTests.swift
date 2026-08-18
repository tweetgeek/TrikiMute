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
