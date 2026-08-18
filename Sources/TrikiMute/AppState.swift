import Foundation
import Observation
import TrikiMuteCore

/// Jedyne źródło prawdy dla interfejsu.
@MainActor
@Observable
final class AppState {
    private(set) var stanKapsla: PolaczenieKapsla = .rozlaczony
    private(set) var bateria: Int?
    private(set) var rssi: Int?
    private(set) var cel: ProbeResult?
    /// Ustawiane, gdy sonda w ogóle nie mogła sprawdzić Celu — najczęściej brak
    /// zgody na Automation albo wyłączone wykonywanie JavaScriptu. Puste, gdy
    /// sonda odpowiedziała, choćby brakiem Celu.
    private(set) var bladSondy: String?
    private(set) var ostatniaAkcja: String = "—"
    private(set) var bladAutostartu: String?

    private let polaczenie: any KapselConnection
    private let controller: MeetController
    private let kolejka: any SkryptowaKolejka
    private var sonda: Timer?
    private var sondaWToku = false
    /// Akcja w locie. Naciśnięcia, które przychodzą, zanim poprzednia Akcja
    /// wróci z kolejki, są porzucane, a nie kolejkowane — nieaktualne
    /// przełączenie, wykonane z opóźnieniem po serii naciśnięć, jest gorsze
    /// niż jego brak. Realny wyzwalacz: pierwsze uruchomienie, gdzie
    /// zablokowane okno zgody na Automation zbiera naciśnięcia w kolejce,
    /// a po kliknięciu „Zezwól" wszystkie odpalają się hurtem.
    private var akcjaWToku = false
    /// Sonda zgłoszona w trakcie innej. Nie ginie — ruszy zaraz po niej.
    private var sondaZalegla = false
    /// Numer pokolenia sondy. Wynik ze starego pokolenia jest ignorowany:
    /// rozłączenie podbija numer, więc odpowiedź wysłana przed rozłączeniem
    /// nie wpisze z powrotem danych urządzenia, którego już nie ma.
    private var pokolenieSondy = 0

    /// Odstęp sondy. Sonda chodzi wyłącznie przy uzbrojonym Kapslu — poza
    /// rozmową nie ma czego odpytywać.
    private static let odstepSondy: TimeInterval = 3.0

    /// Skrypty wykonują się poza głównym wątkiem. `NSAppleScript` blokuje na
    /// czas rozmowy z przeglądarką, a przy pierwszym użyciu także na czas
    /// odpowiedzi użytkownika na pytanie o zgodę — na głównym wątku zamroziłoby
    /// to pasek menu. Kolejka jest szeregowa, więc sonda i Akcje nie wchodzą
    /// sobie w drogę. Stan zmieniamy wyłącznie po powrocie na główny wątek.
    ///
    /// `polaczenie`, `controller` i `kolejka` są parametrami inicjalizatora —
    /// wyłącznie po to, żeby testy mogły podstawić atrapy zamiast prawdziwego
    /// CoreBluetooth, AppleScriptu i wątków w tle. Wartości domyślne
    /// odtwarzają dotychczasowe, produkcyjne połączenia, więc `AppState()` w
    /// `TrikiMuteApp.swift` nie musi się zmienić.
    ///
    /// `polaczenie` domyślnie `nil` zamiast `TrikiConnection()` wprost: wyrażenia
    /// domyślne parametrów nie dziedziczą izolacji `@MainActor` inicjalizatora,
    /// więc budowa `TrikiConnection` (klasy `@MainActor`) musi się odbyć w ciele
    /// `init`, a nie w jego liście parametrów.
    init(
        polaczenie: (any KapselConnection)? = nil,
        controller: MeetController = MeetController(runner: AppleScriptRunner()),
        kolejka: any SkryptowaKolejka = DomyslnaKolejkaSkryptow(
            kolejkaTla: DispatchQueue(label: "pl.tweetgeek.trikimute.skrypty")
        )
    ) {
        let polaczenie = polaczenie ?? TrikiConnection()
        self.polaczenie = polaczenie
        self.controller = controller
        self.kolejka = kolejka
        polaczenie.onState = { [weak self] stan in
            guard let self else { return }
            stanKapsla = stan
            stan == .uzbrojony ? uruchomSonde() : zatrzymajSonde()
        }
        polaczenie.onBattery = { [weak self] in self?.bateria = $0 }
        polaczenie.onRSSI = { [weak self] in self?.rssi = $0 }
        polaczenie.onEvent = { [weak self] zdarzenie in
            self?.wykonaj(zdarzenie == .press ? .microphone : .camera)
        }
        polaczenie.start()
    }

    /// Nazwa symbolu SF dla ikony w pasku menu.
    var nazwaIkony: String {
        switch stanKapsla {
        case .blad: return "exclamationmark.triangle"
        case .rozlaczony, .szukam: return "circle.dotted"
        case .uzbrojony:
            if bladSondy != nil { return "exclamationmark.triangle" }
            return cel?.micMuted == true ? "mic.slash.fill" : "mic.fill"
        }
    }

    var opisKapsla: String {
        switch stanKapsla {
        case .rozlaczony: return "Kapsel rozłączony"
        case .szukam: return "Szukam Kapsla — naciśnij przycisk, żeby go obudzić"
        case .uzbrojony: return "Kapsel uzbrojony"
        case .blad(let opis): return opis
        }
    }

    var opisCelu: String {
        if let bladSondy { return "Nie mogę sprawdzić Celu: \(bladSondy)" }
        guard let cel else { return "Brak Celu — nie ma czego wyciszyć" }
        return "\(cel.browser): mikrofon \(cel.micMuted ? "wyciszony" : "aktywny"), "
            + "kamera \(cel.cameraOff ? "wyłączona" : "włączona")"
    }

    var opisAutostartu: String {
        switch LoginItem.stan {
        case .wlaczony: return "✓ Uruchamiaj przy logowaniu"
        case .wylaczony: return "Uruchamiaj przy logowaniu"
        case .wymagaZatwierdzenia: return "Uruchamiaj przy logowaniu — zatwierdź w Ustawieniach"
        }
    }

    func wykonaj(_ action: MeetAction) {
        guard !akcjaWToku else {
            // Cisza tutaj odtworzyłaby dokładnie tę klasę defektu, którą ta
            // gałąź eliminowała: naciśnięcie ma być słyszalnie potwierdzone,
            // nawet gdy zostaje porzucone.
            let wynik = ActionOutcome.failed("poprzednia Akcja jeszcze trwa, pominięto")
            Feedback.zagraj(wynik)
            ostatniaAkcja = opis(action, wynik)
            return
        }
        akcjaWToku = true
        // NSWorkspace pytamy jeszcze na głównym wątku.
        let przegladarki = BrowserOrder.uporzadkowane()
        let controller = self.controller
        kolejka.uruchom(
            tlo: { controller.perform(action, browsers: przegladarki) },
            glowny: { [weak self] wynik in
                guard let self else { return }
                akcjaWToku = false
                Feedback.zagraj(wynik)
                ostatniaAkcja = opis(action, wynik)
                // Meet aktualizuje DOM asynchronicznie po kliknięciu — odczyt
                // musi poczekać, inaczej zobaczymy stan sprzed Akcji.
                kolejka.poCzasie(0.3) { [weak self] in
                    self?.odswiezCel()
                }
            }
        )
    }

    func zapomnijKapsel() {
        polaczenie.forget()
    }

    func przelaczAutostart() {
        bladAutostartu = LoginItem.przelacz()
    }

    private func opis(_ action: MeetAction, _ wynik: ActionOutcome) -> String {
        let co = action == .microphone ? "Mikrofon" : "Kamera"
        switch wynik {
        case .performed: return "\(co): przełączono"
        case .noTarget: return "\(co): brak Celu"
        case .failed(let blad): return "\(co): błąd — \(blad)"
        }
    }

    private func uruchomSonde() {
        guard sonda == nil else { return }
        odswiezCel()
        sonda = Timer.scheduledTimer(withTimeInterval: Self.odstepSondy, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.odswiezCel() }
        }
    }

    private func zatrzymajSonde() {
        sonda?.invalidate()
        sonda = nil
        cel = nil
        rssi = nil
        bladSondy = nil
        sondaWToku = false
        sondaZalegla = false
        // Unieważnia sondę będącą w locie — jej wynik dotyczy stanu sprzed
        // rozłączenia i nie ma prawa wrócić na ekran.
        pokolenieSondy += 1
    }

    /// Jeden przebieg sondy: gdzie jest Cel, w jakim jest stanie i jak mocny
    /// jest sygnał Kapsla. Siła sygnału przychodzi asynchronicznie przez onRSSI.
    ///
    /// Sonda nie może się piętrzyć: gdyby przeglądarka się zawiesiła, timer co
    /// 3 sekundy dokładałby kolejne wywołania bez końca. Ale nie może też
    /// gubić zgłoszeń — odświeżenie po Akcji jest celowe i zniknięcie go
    /// zostawiałoby na ekranie stan sprzed Akcji aż do następnego cyklu.
    /// Stąd zaległość: w kolejce czeka najwyżej jedna sonda i rusza od razu
    /// po bieżącej.
    ///
    /// Widoczność pakietowa (nie `private`) celowo — testy `AppState`
    /// wywołują tę metodę wprost, żeby przypiąć wyścigi bez czekania na
    /// timer albo prawdziwe rozłączenie BLE.
    func odswiezCel() {
        // Sonda ma sens wyłącznie przy uzbrojonym Kapslu. Bez tej bramki
        // odświeżenie opóźnione po Akcji mogłoby wystartować już po
        // rozłączeniu i wpisać Cel dla urządzenia, którego nie ma.
        guard stanKapsla == .uzbrojony else { return }
        guard !sondaWToku else {
            sondaZalegla = true
            return
        }
        sondaWToku = true
        sondaZalegla = false
        pokolenieSondy += 1
        let moje = pokolenieSondy
        let przegladarki = BrowserOrder.uporzadkowane()
        let controller = self.controller
        polaczenie.odczytajRSSI()
        kolejka.uruchom(
            tlo: { controller.probe(browsers: przegladarki) },
            glowny: { [weak self] wynik in
                guard let self else { return }
                sondaWToku = false
                // Wynik przedawniony: w międzyczasie sonda została zatrzymana
                // albo wystartowała nowsza. Nie ma prawa niczego nadpisać.
                guard moje == pokolenieSondy else { return }
                switch wynik {
                case .target(let cel):
                    self.cel = cel
                    bladSondy = nil
                case .noTarget:
                    cel = nil
                    bladSondy = nil
                case .failed(let opis):
                    // Awaria sondy nie może udawać braku rozmowy — pasek menu
                    // ma pokazać przyczynę, a nie „wszystko gra".
                    cel = nil
                    bladSondy = opis
                }
                if sondaZalegla { odswiezCel() }
            }
        )
    }
}
