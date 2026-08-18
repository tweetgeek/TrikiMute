import Foundation
import Testing
@testable import TrikiMuteCore

/// Podaje rozpoznawaczowi ciąg próbek co 10 ms i zwraca wszystkie zdarzenia.
private func odtworz(
    _ recognizer: inout ButtonRecognizer,
    wcisniety: Bool,
    przez czas: TimeInterval,
    od start: TimeInterval
) -> [ButtonEvent] {
    var zdarzenia: [ButtonEvent] = []
    var t = start
    while t < start + czas {
        if let e = recognizer.consume(ButtonSample(pressed: wcisniety, timestamp: t)) {
            zdarzenia.append(e)
        }
        t += 0.01
    }
    return zdarzenia
}

@Test func krotkieWcisniecieDajeNacisniecie() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 0.3, od: 0.2)
    let po = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.5)
    #expect(po == [.press])
}

@Test func przytrzymanieDajeHoldWMomenciePrzekroczeniaProgu() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    let wtrakcie = odtworz(&r, wcisniety: true, przez: 1.5, od: 0.2)
    #expect(wtrakcie == [.hold])
}

@Test func poPrzytrzymaniuPuszczenieNieDajeNacisniecia() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 1.5, od: 0.2)
    let po = odtworz(&r, wcisniety: false, przez: 0.5, od: 1.7)
    #expect(po.isEmpty)
}

@Test func tuzPonizejProguToNacisniecie() {
    var r = ButtonRecognizer(tuning: .init(hold: 0.4, debounce: 0.03, cooldown: 0.0))
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    let wtrakcie = odtworz(&r, wcisniety: true, przez: 0.35, od: 0.2)
    #expect(wtrakcie.isEmpty)
    let po = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.55)
    #expect(po == [.press])
}

@Test func drganieStykuJestTlumione() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    // Trzy zbocza w ciągu 20 ms — poniżej progu debounce.
    var zdarzenia: [ButtonEvent] = []
    for (i, stan) in [true, false, true].enumerated() {
        if let e = r.consume(ButtonSample(pressed: stan, timestamp: 0.2 + Double(i) * 0.005)) {
            zdarzenia.append(e)
        }
    }
    #expect(zdarzenia.isEmpty)
}

@Test func cooldownTlumiDrugieNacisniecie() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 0.2, od: 0.2)
    let pierwsze = odtworz(&r, wcisniety: false, przez: 0.1, od: 0.4)
    #expect(pierwsze == [.press])
    _ = odtworz(&r, wcisniety: true, przez: 0.1, od: 0.5)
    let drugie = odtworz(&r, wcisniety: false, przez: 0.1, od: 0.6)
    #expect(drugie.isEmpty)
}

@Test func ciaglyStanPuszczonyNieDajeZdarzen() {
    var r = ButtonRecognizer()
    let zdarzenia = odtworz(&r, wcisniety: false, przez: 5.0, od: 0.0)
    #expect(zdarzenia.isEmpty)
}
