import Foundation

/// Abstrakcja dwóch skoków wątku wokół wykonania skryptu AppleScript: praca w
/// tle (blokująca, więc poza głównym wątkiem), a potem powrót na główny wątek
/// z wynikiem. `poCzasie` to ten sam wzorzec dla odświeżenia Celu opóźnionego
/// po Akcji.
///
/// Istnieje wyłącznie po to, żeby `AppState` dało się przetestować
/// deterministycznie — atrapa w testach wykonuje `tlo` od razu, a `glowny`
/// dopiero na żądanie testu, więc testy nie potrzebują snu ani realnych
/// opóźnień.
@MainActor
protocol SkryptowaKolejka {
    func uruchom<T>(tlo: @escaping () -> T, glowny: @escaping (T) -> Void)
    func poCzasie(_ opoznienie: TimeInterval, wykonaj: @escaping () -> Void)
}

/// Produkcyjna implementacja: `tlo` na szeregowej kolejce w tle, `glowny` i
/// opóźnione wywołania z powrotem na głównym wątku.
struct DomyslnaKolejkaSkryptow: SkryptowaKolejka {
    let kolejkaTla: DispatchQueue

    func uruchom<T>(tlo: @escaping () -> T, glowny: @escaping (T) -> Void) {
        kolejkaTla.async {
            let wynik = tlo()
            DispatchQueue.main.async { glowny(wynik) }
        }
    }

    func poCzasie(_ opoznienie: TimeInterval, wykonaj: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + opoznienie, execute: wykonaj)
    }
}
