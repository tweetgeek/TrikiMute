import Foundation
import TrikiMuteCore

/// Runs AppleScript via `NSAppleScript`.
///
/// The most common errors that surface here:
/// `-1743` — no Automation permission in System Settings,
/// `-2700` / a JavaScript-related message — "Allow JavaScript from Apple
/// Events" disabled in the browser's `View → Developer` menu.
final class AppleScriptRunner: ScriptRunner {
    struct Failure: LocalizedError {
        let code: Int
        let message: String
        var errorDescription: String? { "AppleScript \(code): \(message)" }
    }

    func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw Failure(code: 0, message: "Nie udało się zbudować skryptu")
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            throw Failure(
                code: info[NSAppleScript.errorNumber] as? Int ?? 0,
                message: info[NSAppleScript.errorMessage] as? String ?? "nieznany błąd"
            )
        }
        guard let text = result.stringValue else {
            // A missing string value is an anomaly, not an answer. Returning
            // "NONE" would masquerade as no call in progress, i.e. falsely
            // claim that everything is fine.
            throw Failure(code: 0, message: "Skrypt nie zwrócił wartości tekstowej")
        }
        return text
    }
}
