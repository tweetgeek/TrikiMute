import Foundation

/// Wykonawca skryptów. Produkcyjna implementacja opakowuje `NSAppleScript`,
/// testowa zwraca zaprogramowane odpowiedzi.
public protocol ScriptRunner {
    func run(_ source: String) throws -> String
}

/// Wynik sondy: gdzie jest Cel i w jakim jest stanie.
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

/// Steruje mikrofonem i kamerą w Celu.
public struct MeetController {
    private let runner: ScriptRunner

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    /// Szuka Celu w podanych przeglądarkach, w kolejności. Zwraca stan
    /// pierwszej karty, w której jest komplet przycisków, albo `nil`.
    public func probe(browsers: [String]) -> ProbeResult? {
        for browser in browsers {
            guard let odpowiedz = wykonaj(MeetScripts.probeJS(), in: browser),
                  odpowiedz.count == 2 else { continue }
            let znaki = Array(odpowiedz)
            return ProbeResult(
                browser: browser,
                micMuted: znaki[0] == "1",
                cameraOff: znaki[1] == "1"
            )
        }
        return nil
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

    private func wykonaj(_ javascript: String, in browser: String) -> String? {
        let skrypt = MeetScripts.appleScript(browser: browser, javascript: javascript)
        guard let odpowiedz = try? runner.run(skrypt), odpowiedz != "NONE" else { return nil }
        return odpowiedz
    }
}
