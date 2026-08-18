import AppKit
import TrikiMuteCore

/// Audible signals confirming the outcome of an Action.
///
/// The menu bar is a poor channel for failure notifications, because the
/// whole point of the device is that you're not looking at the screen. Sound
/// reaches your headphones — where you actually are during a call.
///
/// An unarmed device won't trigger any sound — the app doesn't know it was
/// pressed. Silence in that situation is unavoidable and signals the absence
/// of Readiness.
enum Feedback {
    private static let success = "Tink"
    private static let noTarget = "Pop"
    private static let failure = "Basso"

    static func play(_ outcome: ActionOutcome) {
        let name: String
        switch outcome {
        case .performed: name = success
        case .noTarget: name = noTarget
        case .failed: name = failure
        }
        NSSound(named: name)?.play()
    }
}
