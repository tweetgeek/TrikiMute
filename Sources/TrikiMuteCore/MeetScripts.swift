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

    /// Opakowuje JS w skrypt szukający Celu wśród kart danej przeglądarki.
    /// Karta nie musi być aktywna ani na wierzchu — to jest cały sens Apple
    /// Events zamiast skrótu klawiszowego.
    public static func appleScript(browser: String, javascript: String) -> String {
        """
        tell application "\(browser)"
            if it is not running then return "NONE"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "meet.google.com" then
                        set wynik to execute t javascript "\(javascript)"
                        if wynik is not "NONE" then return wynik
                    end if
                end repeat
            end repeat
        end tell
        return "NONE"
        """
    }
}
