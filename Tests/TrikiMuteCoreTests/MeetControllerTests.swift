import Foundation
import Testing
@testable import TrikiMuteCore

/// Wykonawca-atrapa: zwraca zaprogramowane odpowiedzi i zapamiętuje skrypty.
private final class FakeRunner: ScriptRunner {
    var odpowiedzi: [String]
    private(set) var wykonane: [String] = []

    init(_ odpowiedzi: [String]) { self.odpowiedzi = odpowiedzi }

    func run(_ source: String) throws -> String {
        wykonane.append(source)
        return odpowiedzi.isEmpty ? "NONE" : odpowiedzi.removeFirst()
    }
}

private struct RunnerError: Error {}

private final class ThrowingRunner: ScriptRunner {
    func run(_ source: String) throws -> String { throw RunnerError() }
}

@Test func sondaZwracaBrakCeluGdyZadnaPrzegladarkaNieMaMeet() {
    let runner = FakeRunner(["NONE", "NONE"])
    let c = MeetController(runner: runner)
    #expect(c.probe(browsers: ["Google Chrome", "Brave Browser"]) == nil)
    #expect(runner.wykonane.count == 2)
}

@Test func sondaDekodujeStanMikrofonuIKamery() {
    // Format odpowiedzi: dwa znaki, kolejno mikrofon i kamera, 1 = wyłączone.
    let runner = FakeRunner(["10"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Google Chrome"])
    #expect(wynik == ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false))
}

@Test func sondaZatrzymujeSieNaPierwszejPrzegladarceZCelem() {
    let runner = FakeRunner(["01", "11"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(wynik?.browser == "Brave Browser")
    #expect(wynik?.micMuted == false)
    #expect(wynik?.cameraOff == true)
    #expect(runner.wykonane.count == 1)
}

@Test func sondaPomijaPrzegladarkeKtoraRzucilaBlad() {
    let c = MeetController(runner: ThrowingRunner())
    #expect(c.probe(browsers: ["Google Chrome"]) == nil)
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
