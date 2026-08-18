import AppKit
import TrikiMuteCore

/// Sygnały dźwiękowe potwierdzające wynik Akcji.
///
/// Pasek menu jest złym kanałem na komunikat o niepowodzeniu, bo cała wartość
/// Kapsla polega na tym, że nie patrzysz na ekran. Dźwięk trafia do słuchawek,
/// czyli tam, gdzie faktycznie jesteś podczas rozmowy.
///
/// Nieuzbrojony Kapsel nie wywoła żadnego dźwięku — aplikacja nie wie o jego
/// naciśnięciu. Cisza w tej sytuacji jest nieunikniona i oznacza brak Gotowości.
enum Feedback {
    private static let sukces = "Tink"
    private static let brakCelu = "Pop"
    private static let blad = "Basso"

    static func zagraj(_ wynik: ActionOutcome) {
        let nazwa: String
        switch wynik {
        case .performed: nazwa = sukces
        case .noTarget: nazwa = brakCelu
        case .failed: nazwa = blad
        }
        NSSound(named: nazwa)?.play()
    }
}
