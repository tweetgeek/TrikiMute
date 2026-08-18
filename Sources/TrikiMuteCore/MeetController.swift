import Foundation

/// Wykonawca skryptów. Produkcyjna implementacja opakowuje `NSAppleScript`,
/// testowa zwraca zaprogramowane odpowiedzi.
public protocol ScriptRunner {
    func run(_ source: String) throws -> String
}

/// Gdzie jest Cel i w jakim jest stanie.
public struct ProbeResult: Equatable, Sendable {
    public let browser: String
    public let micMuted: Bool
    public let cameraOff: Bool

    public init(browser: String, micMuted: Bool, cameraOff: Bool) {
        self.browser = browser
        self.micMuted = micMuted
        self.cameraOff = cameraOff
    }
}

/// Wynik Akcji. Rozróżnienie `noTarget` od `failed` jest celowe: pierwsze
/// znaczy „nie ma czego wyciszyć", drugie „miałem co zrobić i nie wyszło".
public enum ActionOutcome: Equatable, Sendable {
    case performed
    case noTarget
    case failed(String)
}

/// Wynik sondy. To samo rozróżnienie co w `ActionOutcome` i z tego samego
/// powodu: gdyby awaria zwracała „brak Celu", pasek menu twierdziłby, że
/// wszystko gra, podczas gdy w rzeczywistości cofnięto zgodę na Automation
/// albo wyłączono wykonywanie JavaScriptu w przeglądarce.
public enum ProbeOutcome: Equatable, Sendable {
    case target(ProbeResult)
    case noTarget
    case failed(String)
}

/// Steruje mikrofonem i kamerą w Celu.
public struct MeetController {
    private let runner: ScriptRunner

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    /// Szuka Celu w podanych przeglądarkach, w kolejności. Zwraca stan
    /// pierwszej karty, w której jest komplet przycisków; jeśli żadna nie ma
    /// Celu, rozróżnia „nigdzie nie ma rozmowy" od „nie dało się sprawdzić".
    public func probe(browsers: [String]) -> ProbeOutcome {
        var ostatniBlad: String?
        for browser in browsers {
            let skrypt = MeetScripts.appleScript(
                browser: browser,
                javascript: MeetScripts.probeJS()
            )
            do {
                let odpowiedz = try runner.run(skrypt)
                // Sentinel „NONE" ma cztery znaki, więc odpada tu naturalnie.
                guard odpowiedz.count == 2 else { continue }
                let znaki = Array(odpowiedz)
                return .target(ProbeResult(
                    browser: browser,
                    micMuted: znaki[0] == "1",
                    cameraOff: znaki[1] == "1"
                ))
            } catch {
                ostatniBlad = String(describing: error)
            }
        }
        if let ostatniBlad { return .failed(ostatniBlad) }
        return .noTarget
    }

    /// Wykonuje Akcję w pierwszej przeglądarce, w której jest Cel.
    public func perform(_ action: MeetAction, browsers: [String]) -> ActionOutcome {
        var ostatniBlad: String?
        for browser in browsers {
            do {
                let odpowiedz = try runner.run(
                    MeetScripts.appleScript(browser: browser, javascript: MeetScripts.toggleJS(action))
                )
                if odpowiedz == "OK" { return .performed }
            } catch {
                ostatniBlad = String(describing: error)
            }
        }
        if let ostatniBlad { return .failed(ostatniBlad) }
        return .noTarget
    }
}
