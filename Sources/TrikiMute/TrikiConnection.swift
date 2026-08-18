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

    private var central: CBCentralManager!
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

    /// Requests a signal strength reading. The answer arrives asynchronously
    /// in `peripheral(_:didReadRSSI:error:)`.
    func readRSSI() {
        peripheral?.readRSSI()
    }

    /// Forgets the device and goes back to waiting. Use when you need to
    /// pair a different one — the app won't reconnect until `startPairing()`
    /// is called again.
    ///
    /// Also ends any pairing session in progress: `central` — and therefore
    /// the scan invariant (never left running with nothing able to stop it)
    /// — belongs solely to this type, so it has to hold regardless of what
    /// a caller does, not merely because the menu is expected to prevent
    /// calling this mid-pairing.
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
    func startPairing() {
        guard central?.state == .poweredOn else { return }
        pairing = PairingSession()
        central.scanForPeripherals(withServices: nil, options: nil)
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

    /// Persists the identifier of the device currently connected — the one
    /// `choose(_:)` picked — as the remembered device. The only place that
    /// writes `knownDeviceKey`: `didDiscover` no longer does, and
    /// `choose(_:)` only connects, so an unconfirmed candidate can never
    /// become "the" device.
    ///
    /// Stops the scan defensively, same as `cancelPairing()`: the expected
    /// caller only confirms after `choose(_:)` already stopped it, but
    /// nothing here should depend on being called in the right order —
    /// called out of sequence, this must still leave the scan invariant
    /// intact rather than end the session with scanning still running and
    /// no way left to stop it.
    func confirmPairing() {
        guard let peripheral else { return }
        central.stopScan()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownDeviceKey)
        pairing = nil
    }

    /// Known device: a pending `connect()`. No saved device: does nothing —
    /// the app waits for `startPairing()` rather than connecting to
    /// anything on its own.
    private func resumeSearch() {
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
}

extension TrikiConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: resumeSearch()
            case .poweredOff: onState?(.error("Bluetooth jest wyłączony"))
            case .unauthorized: onState?(.error("Brak zgody na Bluetooth"))
            case .unsupported: onState?(.error("Ten Mac nie obsługuje Bluetooth LE"))
            default: onState?(.disconnected)
            }
        }
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
            // Deliberate disconnect: forget() already cleared peripheral
            // before the callback arrived. Without this guard, "Forget
            // Device" would immediately reconnect, and the scan would save
            // the identifier right back.
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
