import Foundation
import Testing
@testable import TrikiMuteCore

/// Wykonawca-atrapa: oddaje kolejne zaprogramowane odpowiedzi i zapamiętuje
/// wykonane skrypty. Wartość "THROW" oznacza, że dane wywołanie ma rzucić —
/// dzięki temu da się odtworzyć sytuację, w której jedna przeglądarka zawodzi,
/// a druga odpowiada normalnie.
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

private struct RunnerError: Error {}

private final class ThrowingRunner: ScriptRunner {
    func run(_ source: String) throws -> String { throw RunnerError() }
}

@Test func sondaZwracaBrakCeluGdyZadnaPrzegladarkaNieMaMeet() {
    let runner = FakeRunner(["NONE", "NONE"])
    let c = MeetController(runner: runner)
    #expect(c.probe(browsers: ["Google Chrome", "Brave Browser"]) == .noTarget)
    #expect(runner.wykonane.count == 2)
}

@Test func sondaDekodujeStanMikrofonuIKamery() {
    // Format odpowiedzi: dwa znaki, kolejno mikrofon i kamera, 1 = wyłączone.
    let runner = FakeRunner(["10"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Google Chrome"])
    #expect(wynik == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func sondaZatrzymujeSieNaPierwszejPrzegladarceZCelem() {
    let runner = FakeRunner(["01", "11"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(wynik == .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    #expect(runner.wykonane.count == 1)
}

@Test func sondaZglaszaBladGdyWykonawcaRzuca() {
    // Kluczowe rozróżnienie: awaria nie może udawać braku rozmowy, bo pasek
    // menu pokazałby wtedy „wszystko gra" przy cofniętej zgodzie na Automation.
    let c = MeetController(runner: ThrowingRunner())
    if case .failed = c.probe(browsers: ["Google Chrome"]) {
        // oczekiwane
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func sondaZnajdujeCelMimoBleduPierwszejPrzegladarki() {
    let runner = FakeRunner(["THROW", "10"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(wynik == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func sondaZglaszaBladGdyJednaPrzegladarkaRzucaADrugaNieMaCelu() {
    let runner = FakeRunner(["THROW", "NONE"])
    let c = MeetController(runner: runner)
    if case .failed = c.probe(browsers: ["Brave Browser", "Google Chrome"]) {
        // oczekiwane
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

@Test func akcjaZglaszaBrakCelu() {
    let runner = FakeRunner(["NONE"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .noTarget)
}

@Test func akcjaZglaszaSukces() {
    let runner = FakeRunner(["OK"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .performed)
}

@Test func akcjaZglaszaBladWykonawcy() {
    let c = MeetController(runner: ThrowingRunner())
    if case .failed = c.perform(.camera, browsers: ["Google Chrome"]) {
        // oczekiwane
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func akcjaUdajeSieGdyPierwszaPrzegladarkaRzucaADrugaDziala() {
    let runner = FakeRunner(["THROW", "OK"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Brave Browser", "Google Chrome"]) == .performed)
}

@Test func akcjaZglaszaBladGdyJednaPrzegladarkaRzucaADrugaNieMaCelu() {
    let runner = FakeRunner(["THROW", "NONE"])
    let c = MeetController(runner: runner)
    if case .failed = c.perform(.microphone, browsers: ["Brave Browser", "Google Chrome"]) {
        // oczekiwane
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

@Test func javascriptZCudzyslowemJestEscapowany() {
    // appleScript() musi być poprawne dla dowolnego wejścia, a nie polegać na
    // tym, że generatory trzymają się apostrofów.
    let s = MeetScripts.appleScript(browser: "Google Chrome", javascript: "return \"x\"")
    #expect(s.contains("\\\"x\\\""))
}

@Test func skryptMikrofonuIKameryCelujaWRozneIndeksy() {
    let mic = MeetScripts.toggleJS(.microphone)
    let cam = MeetScripts.toggleJS(.camera)
    #expect(mic != cam)
    #expect(mic.contains("[\(MeetScripts.micIndex)]"))
    #expect(cam.contains("[\(MeetScripts.cameraIndex)]"))
}

@Test func javascriptNieZawieraCudzyslowowLamiacychAppleScript() {
    // JS jest wklejany do literału tekstowego AppleScript, więc podwójne
    // cudzysłowy rozerwałyby skrypt. Cały JS musi używać apostrofów.
    #expect(!MeetScripts.probeJS().contains("\""))
    #expect(!MeetScripts.toggleJS(.microphone).contains("\""))
    #expect(!MeetScripts.toggleJS(.camera).contains("\""))
}

@Test func appleScriptZawieraNazwePrzegladarkiIStrazneWarunki() {
    let s = MeetScripts.appleScript(browser: "Brave Browser", javascript: "1")
    #expect(s.contains("tell application \"Brave Browser\""))
    #expect(s.contains("if it is not running"))
    #expect(s.contains("meet.google.com"))
}

@Test func appleScriptOgraniczaCzasWykonaniaTimeoutem() {
    // Bez tego zawieszona przeglądarka blokowałaby kolejkę skryptów aż do
    // domyślnego, 60-sekundowego limitu AppleScriptu.
    let s = MeetScripts.appleScript(browser: "Google Chrome", javascript: "1")
    #expect(s.contains("with timeout of 5 seconds"))
    #expect(s.contains("end timeout"))
}
