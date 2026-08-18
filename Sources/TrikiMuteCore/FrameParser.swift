import Foundation

/// Składa 14-bajtowe ramki IMU ze strumienia powiadomień BLE i wyciąga z nich
/// stan przycisku. Dane inercyjne są odrzucane — TrikiMute ich nie używa.
///
/// Kapsel nadaje burstami, więc jedno powiadomienie może zawierać wiele ramek
/// albo urwać się w połowie ramki. Parser resynchronizuje się po nagłówku.
public struct FrameParser {
    /// Długość pełnej ramki IMU w bajtach.
    private static let dlugoscRamki = 14
    /// Pierwszy bajt nagłówka. Drugi to flaga przycisku: 0x00 lub 0x01.
    private static let znacznik: UInt8 = 0x22

    private var bufor: [UInt8] = []

    public init() {}

    /// Rozmiar wewnętrznego bufora. Wyłącznie do testów odporności.
    var rozmiarBufora: Int { bufor.count }

    /// Dokłada bajty z jednego powiadomienia i zwraca stany przycisku ze
    /// wszystkich ramek, które udało się z nich złożyć.
    public mutating func consume(_ bytes: [UInt8], at timestamp: TimeInterval) -> [ButtonSample] {
        bufor.append(contentsOf: bytes)
        var wynik: [ButtonSample] = []

        while true {
            guard let start = indeksNaglowka() else {
                // Nic, co mogłoby być początkiem ramki — zachowaj tylko ogon,
                // który jeszcze może się okazać początkiem znacznika.
                if bufor.count > Self.dlugoscRamki {
                    bufor.removeFirst(bufor.count - 1)
                }
                break
            }
            if start > 0 { bufor.removeFirst(start) }
            guard bufor.count >= Self.dlugoscRamki else { break }

            wynik.append(ButtonSample(pressed: bufor[1] == 0x01, timestamp: timestamp))
            bufor.removeFirst(Self.dlugoscRamki)
        }

        return wynik
    }

    /// Indeks pierwszego bajtu, od którego może zaczynać się poprawna ramka.
    private func indeksNaglowka() -> Int? {
        for i in 0..<bufor.count where bufor[i] == Self.znacznik {
            // Drugi bajt musi być flagą przycisku. Jeśli go jeszcze nie ma,
            // czekamy na kolejne powiadomienie zamiast odrzucać znacznik.
            if i + 1 >= bufor.count { return i }
            if bufor[i + 1] == 0x00 || bufor[i + 1] == 0x01 { return i }
        }
        return nil
    }
}
