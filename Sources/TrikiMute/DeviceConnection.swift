import TrikiMuteCore

/// The surface of `TrikiConnection` that `AppState` needs. Exists solely so
/// that `AppState` can be tested without real CoreBluetooth — in production
/// `TrikiConnection` is the only type conforming to this protocol.
@MainActor
protocol DeviceConnection: AnyObject {
    var onEvent: ((ButtonEvent) -> Void)? { get set }
    var onState: ((DeviceState) -> Void)? { get set }
    var onBattery: ((Int) -> Void)? { get set }
    var onRSSI: ((Int) -> Void)? { get set }

    func start()
    func readRSSI()
    func forget()
}

extension TrikiConnection: DeviceConnection {}
