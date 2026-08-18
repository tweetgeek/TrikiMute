import CoreBluetooth
import Foundation
import TrikiMuteCore

/// Device state as seen by the app.
enum DeviceState: Equatable {
    case disconnected
    case searching
    case armed
    case error(String)
}

/// Maintains the connection to the device and turns its stream into button
/// events.
///
/// Two ways a connection comes up:
/// - **Saved device.** The identifier is in `UserDefaults`. A sleeping
///   device doesn't advertise itself over the air, so the app has no way to
///   connect to it on its own initiative. Instead of scanning continuously,
///   we remember the identifier and hold a pending `connect()`;
///   CoreBluetooth brings the connection up on its own as soon as the
///   device speaks up. The first press after a cold start wakes the device
///   and establishes the connection — and by definition doesn't trigger an
///   Action, because at the moment of the press the app wasn't listening
///   yet.
/// - **No saved device.** The app does not connect to anything on its own —
///   it waits for `startPairing()`. That scans and reports candidates via
///   `onCandidates` instead of connecting; the caller shows a list, the
///   user picks one with `choose(_:)`, and only once that choice is
///   confirmed (by a physical button-press count, handled outside this
///   type) does `confirmPairing()` persist the identifier.
@MainActor
final class TrikiConnection: NSObject {
    private enum UUIDs {
        static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let battery = CBUUID(string: "180F")
        static let batteryLevel = CBUUID(string: "2A19")
    }

    /// Command that starts the IMU stream. Without it the device stays
    /// silent, and button state is embedded in the IMU frame header — it
    /// can't be read separately.
    private static let startCommand = Data([0x20, 0x10, 0x00, 0xD0, 0x07, 0x68, 0x00, 0x03])
    private static let knownDeviceKey = "znanyKapselUUID"
    // Filtered from the nonisolated `didDiscover` callback, before hopping
    // to the main actor — a plain immutable String constant is safe to read
    // from any isolation domain, but the compiler can't infer that for a
    // static member of a @MainActor type without this annotation.
    private nonisolated static let nameFragment = "triki"

    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((DeviceState) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?
    var onCandidates: (([DeviceCandidate]) -> Void)?

    /// Typed as the narrow `CentralManaging` seam, not `CBCentralManager`,
    /// so pairing's ordering invariants can be driven directly in tests. See
    /// `CentralManaging`'s doc comment.
    private var central: (any CentralManaging)!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var parser = FrameParser()
    private var recognizer = ButtonRecognizer()

    /// Non-nil for the duration of pairing — from `startPairing()` until
    /// either `confirmPairing()` or `cancelPairing()` ends it.
    private var pairing: PairingSession?

    /// State scoped to one pairing attempt. `candidates` is keyed by
    /// identifier so a repeat advertisement updates signal strength instead
    /// of duplicating. `chosen` is set once `choose(_:)` picks one of them.
    /// Restoring what was there before pairing (the saved device's pending
    /// connection, if any) doesn't need a captured reference — `UserDefaults`
    /// is never written during pairing, so `resumeSearch()` re-reading it
    /// after the fact is sufficient and avoids a second source of truth.
    private struct PairingSession {
        var candidates: [UUID: (info: DeviceCandidate, peripheral: CBPeripheral)] = [:]
        var chosen: CBPeripheral?
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Test seam: injects a fake `CentralManaging` directly, skipping
    /// `start()`'s real `CBCentralManager` construction — there is no real
    /// central manager to start against in a unit test, and no delegate
    /// callbacks will arrive from a fake, so nothing here needs one.
    /// Production code always goes through the no-argument initializer (via
    /// `TrikiConnection()`) and calls `start()`.
    convenience init(central: any CentralManaging) {
        self.init()
        self.central = central
    }

    /// Whether a device identifier is currently saved — independent of
    /// whether that device is reachable right now. See the protocol doc
    /// comment on `DeviceConnection.hasSavedDevice` for why the menu needs
    /// this instead of reading `DeviceState`.
    var hasSavedDevice: Bool {
        UserDefaults.standard.string(forKey: Self.knownDeviceKey) != nil
    }

    /// Requests a signal strength reading. The answer arrives asynchronously
    /// in `peripheral(_:didReadRSSI:error:)`.
    func readRSSI() {
        peripheral?.readRSSI()
    }

    /// Forgets the device and goes back to waiting. Use when there's nothing
    /// to replace it with — a lost or given-away capsule — as opposed to
    /// `startPairing()`, which replaces the saved device with another one.
    /// The app won't reconnect until `startPairing()` is called again:
    /// `resumeSearch()` at the end of this method is not a contradiction —
    /// by the time it runs, `knownDeviceKey` has already been cleared above,
    /// so it finds nothing saved and does nothing. That's deliberate, not
    /// incidental: forgetting must leave the app idle rather than
    /// immediately hunting for the very device it was just told to forget,
    /// and calling `resumeSearch()` here (instead of duplicating its "leave
    /// `.disconnected`" ending) is what makes that fall out for free.
    ///
    /// Also ends any pairing session in progress: `central` — and therefore
    /// the scan invariant (never left running with nothing able to stop it)
    /// — belongs solely to this type, so it has to hold regardless of what
    /// a caller does, not merely because the menu is expected to prevent
    /// calling this mid-pairing. Stopping the scan and clearing `pairing`
    /// before tearing down the connection also means `resumeSearch()`'s own
    /// `guard pairing == nil` never blocks the (already-inert) call at the
    /// end of this method.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.knownDeviceKey)
        if pairing != nil {
            central.stopScan()
            pairing = nil
        }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        onState?(.disconnected)
        resumeSearch()
    }

    /// Enters discovery mode: clears any previous candidate list and starts
    /// scanning. Leaves the saved identifier and the current `peripheral`
    /// (if any) untouched — a saved device already connecting or connected
    /// keeps running undisturbed while the user browses candidates.
    ///
    /// `pairing != nil` guards against a reentrant call: `AppState` already
    /// refuses to call this while its own `pairing` phase is live, but this
    /// type owns `central` and `pairing`'s bookkeeping (`candidates`,
    /// `chosen`), so it — not a well-behaved caller — is what has to hold
    /// the invariant that a session in progress is never silently replaced.
    /// A reentrant call here would reset `pairing` to an empty session and
    /// drop `chosen`, which `cancelPairing()` reads to decide whether to
    /// disconnect a connected candidate and restore the saved device; with
    /// `chosen` gone, it would take the wrong branch. Same reasoning Task
    /// 2's review applied to `confirmPairing()` and `forget()`.
    ///
    /// Returns `false` without doing anything if Bluetooth isn't powered on
    /// or a session is already live — a silent no-op here previously left
    /// `AppState` announcing a search that wasn't actually running (final
    /// review, Issue 1). The Bluetooth-not-ready case doesn't need its own
    /// message: `centralManagerDidUpdateState` already reports the specific
    /// cause via `onState(.error(...))` whenever the state changes, so
    /// `AppState.deviceState` already holds it by the time this refuses.
    @discardableResult
    func startPairing() -> Bool {
        guard central?.state == .poweredOn, pairing == nil else { return false }
        pairing = PairingSession()
        central.scanForPeripherals(withServices: nil, options: nil)
        return true
    }

    /// Stops scanning, connects to the chosen candidate, and lets it run the
    /// normal service-discovery path to `.armed`. If a previous peripheral
    /// (the saved device) was connected or pending, it's disconnected first
    /// — `peripheral` is reassigned before that disconnect is requested, so
    /// the guard in `didDisconnectPeripheral` recognizes it as stale and
    /// doesn't try to reconnect it.
    func choose(_ id: UUID) {
        guard var session = pairing, let candidate = session.candidates[id]?.peripheral else { return }
        central.stopScan()
        let previous = peripheral
        peripheral = candidate
        candidate.delegate = self
        if let previous, previous.identifier != candidate.identifier {
            central.cancelPeripheralConnection(previous)
        }
        session.chosen = candidate
        pairing = session
        central.connect(candidate, options: nil)
        onState?(.searching)
    }

    /// Aborts pairing and restores exactly the state from before
    /// `startPairing()`. Two cases:
    /// - Still collecting (no `choose(_:)` yet): `peripheral` was never
    ///   touched, so there's nothing to undo — a saved device's connection
    ///   (if any) kept running the whole time.
    /// - A candidate was chosen: disconnect it and, if there was a
    ///   previous (saved) peripheral, resume its pending connection via
    ///   `resumeSearch()`; if there wasn't one, settle on `.disconnected`.
    func cancelPairing() {
        guard let session = pairing else { return }
        central.stopScan()
        pairing = nil
        guard let chosen = session.chosen else { return }
        central.cancelPeripheralConnection(chosen)
        peripheral = nil
        rx = nil
        onState?(.disconnected)
        resumeSearch()
    }

    /// Persists the identifier of `pairing.chosen` — the candidate
    /// `choose(_:)` actually picked — as the remembered device. Deliberately
    /// not `peripheral`: that tracks whatever the connection layer currently
    /// has live, which during a `.connecting` reconnect race can momentarily
    /// point somewhere other than the confirmed choice. `chosen` is set once,
    /// by `choose(_:)`, and never reassigned — it's the only value that
    /// actually answers "which device did the user pick," which is the
    /// entire point of pairing (final review, Issue 2).
    ///
    /// Requires an active session with a chosen candidate; returns `false`
    /// and persists nothing otherwise, so a caller can't accidentally
    /// announce success for a device that was never confirmed. The only
    /// place that writes `knownDeviceKey`: `didDiscover` no longer does, and
    /// `choose(_:)` only connects, so an unconfirmed candidate can never
    /// become "the" device.
    ///
    /// Stops the scan defensively, same as `cancelPairing()`: the expected
    /// caller only confirms after `choose(_:)` already stopped it, but
    /// nothing here should depend on being called in the right order —
    /// called out of sequence, this must still leave the scan invariant
    /// intact rather than end the session with scanning still running and
    /// no way left to stop it.
    @discardableResult
    func confirmPairing() -> Bool {
        guard let session = pairing, let chosen = session.chosen else { return false }
        central.stopScan()
        UserDefaults.standard.set(chosen.identifier.uuidString, forKey: Self.knownDeviceKey)
        pairing = nil
        return true
    }

    /// Known device: a pending `connect()`. No saved device: does nothing —
    /// the app waits for `startPairing()` rather than connecting to
    /// anything on its own.
    ///
    /// Refuses outright while a pairing session is live (`pairing != nil`).
    /// Without this, a Bluetooth power-cycle mid-pairing could reassign
    /// `peripheral` to the saved device while `pairing.chosen` still points
    /// at the candidate — hijacking the session (final review, Issue 3).
    /// `handleCentralStateChange(_:)` already avoids calling this in that
    /// case, but the guard belongs here too: nothing about correctness
    /// should depend on every future caller remembering to check first.
    private func resumeSearch() {
        guard pairing == nil else { return }
        guard central?.state == .poweredOn else { return }
        guard let saved = UserDefaults.standard.string(forKey: Self.knownDeviceKey),
              let uuid = UUID(uuidString: saved),
              let known = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return
        }
        onState?(.searching)
        peripheral = known
        known.delegate = self
        central.connect(known, options: nil)
    }

    private func resetRecognition() {
        parser = FrameParser()
        recognizer = ButtonRecognizer()
    }

    /// Reacts to a Bluetooth power/authorization change. Split out from the
    /// `CBCentralManagerDelegate` callback (which hands it a real
    /// `CBCentralManager` the tests can't fake) so it can be exercised
    /// directly and deterministically — see `CentralManaging`.
    ///
    /// Guards `.poweredOn`: with a pairing session live, restarts the scan
    /// instead of resuming the saved device's connection. Before this guard,
    /// a power-cycle mid-pairing called `resumeSearch()` unconditionally,
    /// which during `.searching` never restarted the scan CoreBluetooth had
    /// just dropped (the candidate list would sit empty forever), and during
    /// a chosen candidate's connection reassigned `peripheral` to the saved
    /// device while `pairing.chosen` still pointed at the candidate —
    /// hijacking the session onto the wrong device (final review, Issue 3).
    /// Restarting the scan is safe regardless of how far the session has
    /// gotten: `didDiscover` only ever updates `pairing.candidates`, never
    /// `peripheral` or `central.connect`, and `AppState` only acts on
    /// `onCandidates` while its own phase is `.searching` (see `didDiscover`'s
    /// comment) — so a stray rediscovery during `.connecting`/`.confirming`
    /// is inert.
    func handleCentralStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if pairing != nil {
                central.scanForPeripherals(withServices: nil, options: nil)
            } else {
                resumeSearch()
            }
        case .poweredOff: onState?(.error("Bluetooth jest wyłączony"))
        case .unauthorized: onState?(.error("Brak zgody na Bluetooth"))
        case .unsupported: onState?(.error("Ten Mac nie obsługuje Bluetooth LE"))
        default: onState?(.disconnected)
        }
    }
}

extension TrikiConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in handleCentralStateChange(state) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.lowercased().contains(Self.nameFragment) else { return }
        let rssi = RSSI.intValue
        Task { @MainActor in
            // Outside pairing, discovery does nothing — no saved device
            // means the app waits for the user to start pairing, and it
            // never connects or writes UserDefaults on its own.
            //
            // `stopScan()` in `choose(_:)` doesn't suppress in-flight
            // discoveries synchronously, so a stray one can still land
            // here after a candidate was chosen. That's harmless: this
            // only ever updates `pairing.candidates`, never `self.peripheral`
            // or `central.connect`, so a late discovery can't overwrite or
            // reconnect the chosen device.
            guard var session = pairing else { return }
            session.candidates[peripheral.identifier] = (
                DeviceCandidate(id: peripheral.identifier, name: name, rssi: rssi),
                peripheral
            )
            pairing = session
            let sorted = session.candidates.values.map(\.info).sorted { $0.rssi > $1.rssi }
            onCandidates?(sorted)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            resetRecognition()
            peripheral.discoverServices([UUIDs.nus, UUIDs.battery])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            // Deliberate disconnect: `choose(_:)`, `cancelPairing()`, or
            // `forget()` already reassigned/cleared `peripheral` before this
            // callback arrived — e.g. `choose(_:)` disconnecting a previously
            // connected saved device in favor of the newly chosen candidate,
            // or `forget()` clearing `peripheral` before its own
            // `cancelPeripheralConnection` call resolves. Without this guard,
            // a stale disconnect for that no-longer-current peripheral would
            // immediately reconnect it — for `forget()` specifically, that
            // would resurrect a connection (and a "searching" state) for the
            // very device the user just asked the app to forget.
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            rx = nil
            onState?(.disconnected)
            // The pending connect() will bring the connection back up once
            // the device returns.
            central.connect(peripheral, options: nil)
            onState?(.searching)
        }
    }
}

extension TrikiConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { @MainActor in
                onState?(.error("Nie udało się odczytać usług: \(error.localizedDescription)"))
            }
            return
        }
        Task { @MainActor in
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let serviceUUID = service.uuid
        if let error {
            // A failure on the battery service doesn't disable the app; a
            // failure on NUS means there will be no stream.
            if serviceUUID == UUIDs.nus {
                Task { @MainActor in
                    onState?(.error("Nie udało się odczytać charakterystyk: \(error.localizedDescription)"))
                }
            }
            return
        }
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case UUIDs.tx:
                    // The start command is sent only after subscription is
                    // confirmed, in didUpdateNotificationStateFor.
                    peripheral.setNotifyValue(true, for: ch)
                case UUIDs.rx:
                    rx = ch
                case UUIDs.batteryLevel:
                    peripheral.readValue(for: ch)
                    peripheral.setNotifyValue(true, for: ch)
                default:
                    break
                }
            }
        }
    }

    /// Subscription confirmation. Only here do we know the stream has a way
    /// to arrive — so only here do we send the start command and announce
    /// Arming.
    ///
    /// The order in which CoreBluetooth returns characteristics isn't
    /// guaranteed. Announcing Arming on discovery of RX could therefore fire
    /// before the app had subscribed to TX — i.e. declare readiness for a
    /// connection that had no way to deliver anything.
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let enabled = characteristic.isNotifying
        if let error {
            if uuid == UUIDs.tx {
                Task { @MainActor in
                    onState?(.error("Nie udało się włączyć strumienia: \(error.localizedDescription)"))
                }
            }
            return
        }
        guard uuid == UUIDs.tx, enabled else { return }
        Task { @MainActor in
            guard let rx else {
                onState?(.error("Brak charakterystyki do wysłania komendy startowej"))
                return
            }
            peripheral.writeValue(Self.startCommand, for: rx, type: .withoutResponse)
            onState?(.armed)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let value = RSSI.intValue
        Task { @MainActor in onRSSI?(value) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let bytes = [UInt8](data)
        // The wall clock (Date()) isn't monotonic — a clock going backwards
        // (waking from a long sleep, an NTP correction, a manual time
        // change) would produce negative gaps, and ButtonRecognizer would
        // reject every edge as contact bounce until the clock "caught up"
        // with the previous timestamps. systemUptime always increases, so
        // the gaps between samples stay reliable regardless of system clock
        // changes.
        let now = ProcessInfo.processInfo.systemUptime

        Task { @MainActor in
            switch uuid {
            case UUIDs.batteryLevel:
                if let level = bytes.first { onBattery?(Int(level)) }
            case UUIDs.tx:
                for sample in parser.consume(bytes, at: now) {
                    if let event = recognizer.consume(sample) {
                        onEvent?(event)
                    }
                }
            default:
                break
            }
        }
    }
}
