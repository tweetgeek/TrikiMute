import Foundation

/// Skrypty sterujące rozmową Google Meet.
///
/// Meet nie ma API, a syntetyczny skrót klawiszowy nie zadziała, bo obsługa
/// skrótów reaguje wyłącznie na zaufane zdarzenia — dlatego klikamy realny
/// przycisk w DOM. To jedyne miejsce w kodzie, w którym wolno wymieniać
/// selektory DOM.
public enum MeetScripts {
    /// Atrybut, po którym rozpoznajemy przyciski mikrofonu i kamery.
    /// Świadomie nie `aria-label` — etykieta jest tłumaczona i rozjechałaby się
    /// przy zmianie języka interfejsu.
    public static let buttonSelector = "[data-is-muted]"

    /// Pozycje przycisków w wyniku `querySelectorAll`. Wartości potwierdzone
    /// spikiem z Task 1 (`docs/findings/2026-08-12-meet-dom.md`).
    public static let micIndex = 0
    public static let cameraIndex = 1

    /// Fragment JS wspólny dla sondy i akcji. Zwraca `NONE`, gdy w karcie nie
    /// ma kompletu przycisków — to jest sygnał „brak Celu".
    private static let preambula = """
    var b=document.querySelectorAll('\(buttonSelector)');if(b.length<2)return 'NONE';
    """

    /// Zwraca dwa znaki: stan mikrofonu i kamery, gdzie 1 oznacza wyłączone.
    public static func probeJS() -> String {
        """
        (function(){\(preambula)\
        var f=function(e){return e.getAttribute('data-is-muted')==='true'?'1':'0'};\
        return f(b[\(micIndex)])+f(b[\(cameraIndex)])})()
        """
    }

    /// Klika przycisk odpowiadający akcji. Zwraca `OK` albo `NONE`.
    public static func toggleJS(_ action: MeetAction) -> String {
        let index = action == .microphone ? micIndex : cameraIndex
        return """
        (function(){\(preambula)\
        b[\(index)].click();return 'OK'})()
        """
    }

    /// Escapuje tekst wstawiany do literału tekstowego AppleScript.
    /// Bez tego cudzysłów rozerwałby łańcuch, a odwrotny ukośnik zostałby
    /// zjedzony przez AppleScript, zanim JavaScript zdążyłby go zobaczyć.
    /// Kolejność ma znaczenie: najpierw ukośniki, potem cudzysłowy.
    private static func escapuj(_ tekst: String) -> String {
        tekst
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Opakowuje JS w skrypt szukający Celu wśród kart danej przeglądarki.
    /// Karta nie musi być aktywna ani na wierzchu — to jest cały sens Apple
    /// Events zamiast skrótu klawiszowego.
    ///
    /// Oba wstawiane teksty są escapowane, żeby funkcja była poprawna dla
    /// dowolnego wejścia, a nie tylko dla generatorów trzymających się
    /// apostrofów.
    /// Przeglądarka zawieszona na `execute … javascript` blokowałaby kolejkę
    /// skryptów aż do domyślnego, 60-sekundowego limitu AppleScriptu. Ten
    /// timeout sprowadza to do 5 sekund, więc zawieszona przeglądarka
    /// ujawnia się jako `.failed` (i słyszalne `Basso`) zamiast cichego zwisu.
    public static func appleScript(browser: String, javascript: String) -> String {
        """
        tell application "\(escapuj(browser))"
            with timeout of 5 seconds
                if it is not running then return "NONE"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "meet.google.com" then
                            set wynik to execute t javascript "\(escapuj(javascript))"
                            if wynik is not "NONE" then return wynik
                        end if
                    end repeat
                end repeat
            end timeout
        end tell
        return "NONE"
        """
    }
}
