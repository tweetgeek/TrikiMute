import Foundation
import TrikiMuteCore

/// Wykonuje AppleScript przez `NSAppleScript`.
///
/// Najczęstsze błędy, które tu wypływają:
/// `-1743` — brak zgody na Automation w Ustawieniach systemowych,
/// `-2700` / komunikat o JavaScript — wyłączone „Allow JavaScript from Apple
/// Events" w menu `View → Developer` przeglądarki.
final class AppleScriptRunner: ScriptRunner {
    struct Blad: LocalizedError {
        let kod: Int
        let opis: String
        var errorDescription: String? { "AppleScript \(kod): \(opis)" }
    }

    func run(_ source: String) throws -> String {
        guard let skrypt = NSAppleScript(source: source) else {
            throw Blad(kod: 0, opis: "Nie udało się zbudować skryptu")
        }
        var info: NSDictionary?
        let wynik = skrypt.executeAndReturnError(&info)
        if let info {
            throw Blad(
                kod: info[NSAppleScript.errorNumber] as? Int ?? 0,
                opis: info[NSAppleScript.errorMessage] as? String ?? "nieznany błąd"
            )
        }
        guard let tekst = wynik.stringValue else {
            // Brak wartości tekstowej to anomalia, nie odpowiedź. Zwrócenie
            // "NONE" udawałoby brak rozmowy, czyli mylnie zapewniałoby,
            // że wszystko jest w porządku.
            throw Blad(kod: 0, opis: "Skrypt nie zwrócił wartości tekstowej")
        }
        return tekst
    }
}
