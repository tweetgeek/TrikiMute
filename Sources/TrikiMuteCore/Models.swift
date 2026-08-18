import Foundation

/// Stan przycisku Kapsla odczytany z jednej ramki IMU.
public struct ButtonSample: Equatable, Sendable {
    public let pressed: Bool
    public let timestamp: TimeInterval

    public init(pressed: Bool, timestamp: TimeInterval) {
        self.pressed = pressed
        self.timestamp = timestamp
    }
}

/// Zdarzenie rozpoznane z sekwencji stanów przycisku.
public enum ButtonEvent: Equatable, Sendable {
    /// Naciśnięcie — krótkie wciśnięcie i puszczenie. Odpowiada mikrofonowi.
    case press
    /// Przytrzymanie — wciśnięcie ponad próg czasowy. Odpowiada kamerze.
    case hold
}

/// Akcja wykonywana w Celu.
public enum MeetAction: Equatable, Sendable {
    case microphone
    case camera
}
