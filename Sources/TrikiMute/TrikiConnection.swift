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
/// Arming model: a sleeping device doesn't advertise itself over the air, so
/// the app has no way to connect to it on its own initiative. The first
/// press wakes the device and establishes the connection — and by
/// definition doesn't trigger an Action, because at the moment of the press
/// the app wasn't listening yet. Instead of scanning continuously, we
/// remember the identifier and hold a pending `connect()`; CoreBluetooth
/// will bring the connection up on its own as soon as the device speaks up.
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
    private static let nameFragment = "triki"

    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((DeviceState) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var parser = FrameParser()
    private var recognizer = ButtonRecognizer()

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Requests a signal strength reading. The answer arrives asynchronously
    /// in `peripheral(_:didReadRSSI:error:)`.
    func readRSSI() {
        peripheral?.readRSSI()
    }

    /// Forgets the device and goes back to scanning. Use when you need to
    /// pair a different one.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.knownDeviceKey)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        onState?(.disconnected)
        resumeSearch()
    }

    /// Known device: a pending `connect()`. Unknown: scan by name.
    private func resumeSearch() {
        guard central?.state == .poweredOn else { return }
        onState?(.searching)

        if let saved = UserDefaults.standard.string(forKey: Self.knownDeviceKey),
           let uuid = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            peripheral = known
            known.delegate = self
            central.connect(known, options: nil)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
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
        Task { @MainActor in
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownDeviceKey)
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
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
