import Foundation
import Testing
@testable import TrikiMuteCore

/// Buduje jedną 14-bajtową ramkę IMU o zadanym stanie przycisku.
private func ramka(pressed: Bool) -> [UInt8] {
    [0x22, pressed ? 0x01 : 0x00] + Array(repeating: 0x00, count: 12)
}

@Test func pojedynczaRamkaDajeJedenStan() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: false), at: 1.0)
    #expect(out == [ButtonSample(pressed: false, timestamp: 1.0)])
}

@Test func wcisnietyPrzyciskJestRozpoznawany() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: true), at: 2.5)
    #expect(out == [ButtonSample(pressed: true, timestamp: 2.5)])
}

@Test func dwieSklejoneRamkiWJednymPowiadomieniu() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: false) + ramka(pressed: true), at: 3.0)
    #expect(out.count == 2)
    #expect(out[0].pressed == false)
    #expect(out[1].pressed == true)
}

@Test func ramkaUcietaNaGranicyPowiadomienia() {
    var parser = FrameParser()
    let pelna = ramka(pressed: true)
    let pierwsza = parser.consume(Array(pelna[0..<6]), at: 4.0)
    #expect(pierwsza.isEmpty)
    let druga = parser.consume(Array(pelna[6...]), at: 4.1)
    #expect(druga == [ButtonSample(pressed: true, timestamp: 4.1)])
}

@Test func smieciPrzedNaglowkiemSaOdrzucane() {
    var parser = FrameParser()
    let out = parser.consume([0xFF, 0xAB, 0x09] + ramka(pressed: true), at: 5.0)
    #expect(out == [ButtonSample(pressed: true, timestamp: 5.0)])
}

@Test func nieznanyNaglowekNieBlokujeStrumienia() {
    var parser = FrameParser()
    let smiec: [UInt8] = Array(repeating: 0x99, count: 40)
    _ = parser.consume(smiec, at: 6.0)
    let out = parser.consume(ramka(pressed: false), at: 6.1)
    #expect(out == [ButtonSample(pressed: false, timestamp: 6.1)])
}

@Test func buforNieRosnieWNieskonczonosc() {
    var parser = FrameParser()
    for i in 0..<200 {
        _ = parser.consume(Array(repeating: 0x99, count: 14), at: Double(i))
    }
    #expect(parser.rozmiarBufora < 64)
}
