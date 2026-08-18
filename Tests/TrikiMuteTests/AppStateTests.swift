import Foundation
import Testing
import TrikiMuteCore
@testable import TrikiMute

/// Atrapa `TrikiConnection`: pozwala testom wywoływać `onState`/`onEvent`
/// wprost, bez prawdziwego CoreBluetooth.
@MainActor
private final class FakeKapselConnection: KapselConnection {
    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((PolaczenieKapsla) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?

    private(set) var startCalled = false
    private(set) var forgetCalled = false

    func start() { startCalled = true }
    func odczytajRSSI() {}
    func forget() { forgetCalled = true }
}

private struct RunnerError: Error {}

/// Atrapa `ScriptRunner`: oddaje kolejne zaprogramowane odpowiedzi, w
/// kolejności wywołań. "THROW" rzuca zamiast zwracać — pozwala odtworzyć
/// przeglądarkę, która nie odpowiada. Ten sam wzorzec co w
/// `MeetControllerTests`, zduplikowany celowo: test target nie widzi
/// prywatnych typów innego test targetu.
private final class FakeRunner: ScriptRunner {
    var odpowiedzi: [String]
    private(set) var wykonane: [String] = []

    init(_ odpowiedzi: [String]) { self.odpowiedzi = odpowiedzi }

    func run(_ source: String) throws -> String {
        wykonane.append(source)
        let odpowiedz = odpowiedzi.isEmpty ? "NONE" : odpowiedzi.removeFirst()
        if odpowiedz == "THROW" { throw RunnerError() }
        return odpowiedz
    }
}

/// Kolejka sterowana ręcznie przez test, zamiast prawdziwych wątków i
/// realnych opóźnień.
///
/// `tlo` (praca w tle: `perform`/`probe`) wykonuje się od razu, synchronicznie,
/// na wątku wywołującym — deterministycznie, bez prawdziwego skoku wątku.
/// `glowny` (powrót na główny wątek) i `poCzasie` (odświeżenie opóźnione po
/// Akcji) trafiają do kolejki i czekają na jawne wywołanie `odpal()`. Dzięki
/// temu test może wstrzyknąć inne wywołania dokładnie w oknie, w którym w
/// produkcji trwałby skok między wątkami — czyli odtworzyć wyścig bez snu i
/// bez założeń o czasie.
@MainActor
private final class TestowaKolejka: SkryptowaKolejka {
    private(set) var liczbaUruchomien = 0
    private var oczekujace: [() -> Void] = []

    func uruchom<T>(tlo: @escaping () -> T, glowny: @escaping (T) -> Void) {
        liczbaUruchomien += 1
        let wynik = tlo()
        oczekujace.append { glowny(wynik) }
    }

    func poCzasie(_ opoznienie: TimeInterval, wykonaj: @escaping () -> Void) {
        oczekujace.append(wykonaj)
    }

    /// Wykonuje wszystkie zadania zakolejkowane do tej pory, w kolejności
    /// zgłoszenia. Zadania dodane w trakcie tego wywołania (np. rekurencyjne
    /// `odswiezCel` przy zaległej sondzie) trafiają do kolejnej fali, nie do
    /// bieżącej — dokładnie tak jak realny skok na `DispatchQueue.main`
    /// zaplanowany w trakcie wykonywania innego bloku na tej samej kolejce.
    func odpal() {
        let zadania = oczekujace
        oczekujace = []
        for zadanie in zadania { zadanie() }
    }
}

// MARK: - Wyścig 1: spóźniona sonda po zatrzymaniu

@Test @MainActor func sondaKtoraWracaPoZatrzymaniuNicNiePisze() {
    let polaczenie = FakeKapselConnection()
    // Gdyby ten wynik trafił na ekran, cel przestałby być nil — dokładnie to
    // sprawdzamy poniżej.
    let runner = FakeRunner(["10"])
    let controller = MeetController(runner: runner)
    let kolejka = TestowaKolejka()
    let state = AppState(polaczenie: polaczenie, controller: controller, kolejka: kolejka)

    polaczenie.onState?(.uzbrojony)
    #expect(kolejka.liczbaUruchomien == 1)

    // Rozłączenie w trakcie lotu sondy: podbija pokolenieSondy i czyści stan.
    polaczenie.onState?(.rozlaczony)

    // Spóźniony wynik dociera dopiero teraz.
    kolejka.odpal()

    #expect(state.cel == nil)
    #expect(state.bladSondy == nil)
}

// MARK: - Wyścig 2: nakładające się sondy

@Test @MainActor func drugaSondaZglaszaSieJakoZaleglaANieRownolegla() {
    let polaczenie = FakeKapselConnection()
    let runner = FakeRunner(["10", "01"])
    let controller = MeetController(runner: runner)
    let kolejka = TestowaKolejka()
    let state = AppState(polaczenie: polaczenie, controller: controller, kolejka: kolejka)

    polaczenie.onState?(.uzbrojony)
    #expect(kolejka.liczbaUruchomien == 1)

    // Druga prośba, zanim pierwsza sonda wróciła: ma zostać zaległością, nie
    // wystartować równolegle.
    state.odswiezCel()
    #expect(kolejka.liczbaUruchomien == 1)

    // Dostarczenie pierwszej sondy odpala zaległą drugą automatycznie.
    kolejka.odpal()
    #expect(state.cel == ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false))
    #expect(kolejka.liczbaUruchomien == 2)

    kolejka.odpal()
    #expect(state.cel == ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: true))
}

// MARK: - Wyścig 3: odświeżenie po rozłączeniu

@Test @MainActor func odswiezenieProszoneOPoRozlaczeniuNieStartujeSondy() {
    let polaczenie = FakeKapselConnection()
    let runner = FakeRunner(["10"])
    let controller = MeetController(runner: runner)
    let kolejka = TestowaKolejka()
    let state = AppState(polaczenie: polaczenie, controller: controller, kolejka: kolejka)

    polaczenie.onState?(.uzbrojony)
    kolejka.odpal()
    #expect(kolejka.liczbaUruchomien == 1)

    polaczenie.onState?(.rozlaczony)

    // Prośba o odświeżenie po rozłączeniu nie ma czego odpytywać.
    state.odswiezCel()

    #expect(kolejka.liczbaUruchomien == 1)
    #expect(state.cel == nil)
}

// MARK: - Wyścig 4: udana Akcja czyści poprzedni błąd

@Test @MainActor func udanaAkcjaCzysciPoprzedniBladSondy() {
    let polaczenie = FakeKapselConnection()
    // Kolejność konsumpcji: pierwsza sonda pada na obu przeglądarkach (2
    // wpisy), potem udana Akcja (1 wpis), potem udana druga sonda (1 wpis).
    let runner = FakeRunner(["THROW", "THROW", "OK", "10"])
    let controller = MeetController(runner: runner)
    let kolejka = TestowaKolejka()
    let state = AppState(polaczenie: polaczenie, controller: controller, kolejka: kolejka)

    polaczenie.onState?(.uzbrojony)
    kolejka.odpal()
    #expect(state.bladSondy != nil)

    state.wykonaj(.microphone)
    kolejka.odpal()  // dostarcza wynik Akcji, planuje opóźnione odświeżenie
    kolejka.odpal()  // opóźnione odświeżenie startuje drugą sondę
    kolejka.odpal()  // dostarcza wynik drugiej sondy

    #expect(state.bladSondy == nil)
    #expect(state.ostatniaAkcja == "Mikrofon: przełączono")
}

// MARK: - Finding 3: Akcja w locie jest porzucana, nie kolejkowana

@Test @MainActor func akcjaWTrakcieInnejJestPomijanaANieKolejkowana() {
    let polaczenie = FakeKapselConnection()
    let runner = FakeRunner(["OK"])
    let controller = MeetController(runner: runner)
    let kolejka = TestowaKolejka()
    let state = AppState(polaczenie: polaczenie, controller: controller, kolejka: kolejka)

    state.wykonaj(.microphone)
    state.wykonaj(.camera)

    // Druga Akcja nie ruszyła żadnego skryptu — została porzucona od razu.
    #expect(kolejka.liczbaUruchomien == 1)
    #expect(state.ostatniaAkcja.contains("pominięto"))

    kolejka.odpal()
    #expect(state.ostatniaAkcja == "Mikrofon: przełączono")
}
