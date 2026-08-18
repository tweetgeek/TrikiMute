import Foundation

/// Button state of the device, read from a single IMU frame.
public struct ButtonSample: Equatable, Sendable {
    public let pressed: Bool
    public let timestamp: TimeInterval

    public init(pressed: Bool, timestamp: TimeInterval) {
        self.pressed = pressed
        self.timestamp = timestamp
    }
}

/// Event recognized from a sequence of button states.
public enum ButtonEvent: Equatable, Sendable {
    /// Press — a short press and release. Corresponds to the microphone.
    case press
    /// Hold — held down past the time threshold. Corresponds to the camera.
    case hold
}

/// Action performed on the target.
public enum MeetAction: Equatable, Sendable {
    case microphone
    case camera
}
