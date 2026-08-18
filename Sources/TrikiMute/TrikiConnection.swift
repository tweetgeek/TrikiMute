import CoreBluetooth
import Foundation
import TrikiMuteCore

/// Stan Kapsla widziany przez aplikację.
enum PolaczenieKapsla: Equatable {
    case rozlaczony
    case szukam
    case uzbrojony
    case blad(String)
}

/// Utrzymuje połączenie z Kapslem i zamienia jego strumień na zdarzenia przycisku.
///
/// Model Uzbrojenia: śpiący Kapsel nie reklamuje się w eterze, więc aplikacja
/// nie ma jak się z nim połączyć z własnej inicjatywy. Pierwsze naciśnięcie budzi
/// Kapsel i zestawia połączenie — i z definicji nie wywołuje Akcji, bo w chwili
/// naciśnięcia aplikacja jeszcze nie słuchała. Zamiast ciągłego skanowania
/// zapamiętujemy identyfikator i zawieszamy `connect()`; CoreBluetooth podniesie
/// połączenie samo, gdy tylko Kapsel się odezwie.
@MainActor
final class TrikiConnection: NSObject {
    private enum UUIDy {
        static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let bateria = CBUUID(string: "180F")
        static let poziomBaterii = CBUUID(string: "2A19")
    }

    /// Komenda uruchamiająca strumień IMU. Bez niej Kapsel milczy, a stan
    /// przycisku jest zaszyty w nagłówku ramek IMU — nie da się go czytać osobno.
    private static let komendaStartowa = Data([0x20, 0x10, 0x00, 0xD0, 0x07, 0x68, 0x00, 0x03])
    private static let kluczZnanegoKapsla = "znanyKapselUUID"
    private static let fragmentNazwy = "triki"

    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((PolaczenieKapsla) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var kapsel: CBPeripheral?
    private var rx: CBCharacteristic?
    private var parser = FrameParser()
    private var recognizer = ButtonRecognizer()

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Prosi o pomiar siły sygnału. Odpowiedź przychodzi asynchronicznie
    /// w `peripheral(_:didReadRSSI:error:)`.
    func odczytajRSSI() {
        kapsel?.readRSSI()
    }

    /// Zapomina Kapsel i wraca do skanowania. Do użycia, gdy trzeba sparować inny.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.kluczZnanegoKapsla)
        if let kapsel { central.cancelPeripheralConnection(kapsel) }
        kapsel = nil
        onState?(.rozlaczony)
        wznowPoszukiwania()
    }

    /// Znany Kapsel: zawieszony `connect()`. Nieznany: skan po nazwie.
    private func wznowPoszukiwania() {
        guard central?.state == .poweredOn else { return }
        onState?(.szukam)

        if let zapisany = UserDefaults.standard.string(forKey: Self.kluczZnanegoKapsla),
           let uuid = UUID(uuidString: zapisany),
           let znany = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            kapsel = znany
            znany.delegate = self
            central.connect(znany, options: nil)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func zresetujRozpoznawanie() {
        parser = FrameParser()
        recognizer = ButtonRecognizer()
    }
}

extension TrikiConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: wznowPoszukiwania()
            case .poweredOff: onState?(.blad("Bluetooth jest wyłączony"))
            case .unauthorized: onState?(.blad("Brak zgody na Bluetooth"))
            case .unsupported: onState?(.blad("Ten Mac nie obsługuje Bluetooth LE"))
            default: onState?(.rozlaczony)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let nazwa = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard nazwa.lowercased().contains(Self.fragmentNazwy) else { return }
        Task { @MainActor in
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.kluczZnanegoKapsla)
            kapsel = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            zresetujRozpoznawanie()
            peripheral.discoverServices([UUIDy.nus, UUIDy.bateria])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            rx = nil
            onState?(.rozlaczony)
            // Zawieszony connect() podniesie połączenie, gdy Kapsel wróci.
            central.connect(peripheral, options: nil)
            onState?(.szukam)
        }
    }
}

extension TrikiConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for usluga in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: usluga)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case UUIDy.tx:
                    peripheral.setNotifyValue(true, for: ch)
                case UUIDy.rx:
                    rx = ch
                    peripheral.writeValue(Self.komendaStartowa, for: ch, type: .withoutResponse)
                    onState?(.uzbrojony)
                case UUIDy.poziomBaterii:
                    peripheral.readValue(for: ch)
                    peripheral.setNotifyValue(true, for: ch)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let wartosc = RSSI.intValue
        Task { @MainActor in onRSSI?(wartosc) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let dane = characteristic.value else { return }
        let uuid = characteristic.uuid
        let bajty = [UInt8](dane)
        let teraz = Date().timeIntervalSince1970

        Task { @MainActor in
            switch uuid {
            case UUIDy.poziomBaterii:
                if let poziom = bajty.first { onBattery?(Int(poziom)) }
            case UUIDy.tx:
                for probka in parser.consume(bajty, at: teraz) {
                    if let zdarzenie = recognizer.consume(probka) {
                        onEvent?(zdarzenie)
                    }
                }
            default:
                break
            }
        }
    }
}
