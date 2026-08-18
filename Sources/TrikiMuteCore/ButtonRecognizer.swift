import Foundation

/// Rozpoznaje Naciśnięcia i Przytrzymania z ciągu stanów przycisku.
///
/// Kapsel nadaje *poziom* przycisku w każdej ramce (~104 Hz), a nie zdarzenia,
/// więc rozpoznawanie polega na wykrywaniu zboczy. Przytrzymanie jest zgłaszane
/// w chwili przekroczenia progu, a nie przy puszczeniu — dzięki temu sprzężenie
/// zwrotne przychodzi od razu, bez czekania, aż zdejmiesz palec.
public struct ButtonRecognizer {
    /// Stałe czasowe rozpoznawania. Wszystkie w sekundach.
    public struct Tuning: Sendable {
        public let hold: TimeInterval
        public let debounce: TimeInterval
        public let cooldown: TimeInterval

        public init(hold: TimeInterval, debounce: TimeInterval, cooldown: TimeInterval) {
            self.hold = hold
            self.debounce = debounce
            self.cooldown = cooldown
        }

        public static let domyslne = Tuning(hold: 0.4, debounce: 0.03, cooldown: 0.3)
    }

    private let tuning: Tuning
    private var wcisniety = false
    private var poczatekWcisniecia: TimeInterval = 0
    private var holdZgloszony = false
    private var ostatnieZbocze: TimeInterval = -.greatestFiniteMagnitude
    private var ostatnieZdarzenie: TimeInterval = -.greatestFiniteMagnitude

    public init(tuning: Tuning = .domyslne) {
        self.tuning = tuning
    }

    /// Zwraca zdarzenie, jeśli ta próbka je domyka.
    public mutating func consume(_ sample: ButtonSample) -> ButtonEvent? {
        if sample.pressed != wcisniety {
            guard sample.timestamp - ostatnieZbocze >= tuning.debounce else {
                return nil  // drganie styku
            }
            ostatnieZbocze = sample.timestamp
            wcisniety = sample.pressed

            if wcisniety {
                poczatekWcisniecia = sample.timestamp
                holdZgloszony = false
                return nil
            }
            // Puszczenie. Przytrzymanie już zgłoszone — nie dubluj zdarzenia.
            guard !holdZgloszony else { return nil }
            guard sample.timestamp - poczatekWcisniecia < tuning.hold else { return nil }
            return wyemituj(.press, at: sample.timestamp)
        }

        guard wcisniety, !holdZgloszony else { return nil }
        guard sample.timestamp - poczatekWcisniecia >= tuning.hold else { return nil }
        holdZgloszony = true
        return wyemituj(.hold, at: sample.timestamp)
    }

    private mutating func wyemituj(_ event: ButtonEvent, at timestamp: TimeInterval) -> ButtonEvent? {
        guard timestamp - ostatnieZdarzenie >= tuning.cooldown else { return nil }
        ostatnieZdarzenie = timestamp
        return event
    }
}
