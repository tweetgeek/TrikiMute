import Foundation
import TrikiMuteCore

/// A device seen while collecting candidates during pairing. `rssi` is the
/// signal strength from the most recent advertisement seen for it.
struct DeviceCandidate: Equatable, Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// The surface of `TrikiConnection` that `AppState` needs. Exists solely so
/// that `AppState` can be tested without real CoreBluetooth — in production
/// `TrikiConnection` is the only type conforming to this protocol.
@MainActor
protocol DeviceConnection: AnyObject {
    var onEvent: ((ButtonEvent) -> Void)? { get set }
    var onState: ((DeviceState) -> Void)? { get set }
    var onBattery: ((Int) -> Void)? { get set }
    var onRSSI: ((Int) -> Void)? { get set }
    /// Reports the full candidate list every time it changes during
    /// pairing, sorted by signal strength (strongest first).
    var onCandidates: (([DeviceCandidate]) -> Void)? { get set }

    /// Whether a device identifier is currently saved — independent of
    /// whether that device is reachable right now. Drives the menu's pairing
    /// button label ("Paruj Kapsla" vs "Zmień Kapsla"), which must not be
    /// keyed off `DeviceState`: that can read `.error` (e.g. Bluetooth off)
    /// even though a device is saved, which previously showed the wrong
    /// label.
    var hasSavedDevice: Bool { get }

    func start()
    func readRSSI()

    /// Enters discovery mode: scans and reports candidates via
    /// `onCandidates` instead of connecting to anything automatically. Does
    /// not touch the saved device identifier.
    ///
    /// Returns `false` and does nothing if Bluetooth isn't ready (powered
    /// off, unauthorized, unsupported) or a pairing session is already
    /// active. Refusing silently would leave a caller announcing a search
    /// that isn't actually running — the caller must be able to tell.
    @discardableResult
    func startPairing() -> Bool
    /// Stops scanning and connects to the candidate with this identifier,
    /// carrying it through the normal service-discovery path to `.armed`.
    /// Does not persist anything — the saved identifier is untouched until
    /// `confirmPairing()` is called.
    func choose(_ id: UUID)
    /// Aborts pairing and restores the state from before `startPairing()`
    /// was called: disconnects a candidate if `choose(_:)` already
    /// connected one, and resumes the suspended connection to the saved
    /// device, if there was one.
    func cancelPairing()
    /// Persists the identifier of the candidate `choose(_:)` picked — never
    /// whatever happens to be connected — as the remembered device. The only
    /// place that writes to `UserDefaults`, called once the user's choice has
    /// been confirmed by a physical button-press count (outside this type).
    /// Requires an active session with a chosen candidate; returns `false`
    /// and persists nothing otherwise, so the caller can tell a refusal from
    /// a success instead of announcing confirmation unconditionally.
    @discardableResult
    func confirmPairing() -> Bool
}

extension TrikiConnection: DeviceConnection {}
