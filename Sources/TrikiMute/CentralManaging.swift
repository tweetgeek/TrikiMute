import CoreBluetooth

/// The narrow slice of `CBCentralManager` that `TrikiConnection` actually
/// drives: the five calls it makes on `central`, plus the state it gates
/// every one of them on. Exists so the pairing ordering invariants —
/// refusing to start while Bluetooth isn't ready, never letting a
/// saved-device resume clobber a live pairing session, persisting the right
/// identity — can be pinned with fast unit tests instead of only being
/// checked by hand against real hardware, which was otherwise the only way
/// to exercise this file at all (final review).
///
/// Deliberately does not cover `CBCentralManagerDelegate`/`CBPeripheralDelegate`
/// callbacks or `CBPeripheral` itself: those arrive from real CoreBluetooth
/// and can't be fabricated in a test — `CBPeripheral` has no public
/// initializer — so widening this seam to them would not make more of the
/// file testable, only more of it fake. `TrikiConnectionTests` covers what
/// this does reach — `startPairing()`'s and `confirmPairing()`'s refusal
/// branches, and the power-cycle guard in `handleCentralStateChange(_:)` —
/// and documents what it can't.
@MainActor
protocol CentralManaging: AnyObject {
    var state: CBManagerState { get }
    func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?)
    func stopScan()
    func connect(_ peripheral: CBPeripheral, options: [String: Any]?)
    func cancelPeripheralConnection(_ peripheral: CBPeripheral)
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [CBPeripheral]
}

extension CBCentralManager: CentralManaging {}
