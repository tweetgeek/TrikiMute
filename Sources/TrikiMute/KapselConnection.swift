import TrikiMuteCore

/// Powierzchnia `TrikiConnection`, jakiej potrzebuje `AppState`. Istnieje
/// wyłącznie po to, żeby `AppState` dało się przetestować bez prawdziwego
/// CoreBluetooth — produkcyjnie jedynym typem zgodnym z tym protokołem jest
/// `TrikiConnection`.
@MainActor
protocol KapselConnection: AnyObject {
    var onEvent: ((ButtonEvent) -> Void)? { get set }
    var onState: ((PolaczenieKapsla) -> Void)? { get set }
    var onBattery: ((Int) -> Void)? { get set }
    var onRSSI: ((Int) -> Void)? { get set }

    func start()
    func odczytajRSSI()
    func forget()
}

extension TrikiConnection: KapselConnection {}
