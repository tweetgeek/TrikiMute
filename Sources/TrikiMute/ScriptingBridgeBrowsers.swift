import AppKit
import ScriptingBridge
import TrikiMuteCore

/// Minimal ScriptingBridge declarations for Chrome and Brave.
///
/// The names come from the browsers' scripting dictionaries (`sdef`): the
/// `execute` command with a `javascript` parameter generates the selector
/// `executeJavascript:` on the tab class. A typo here is not a compile error —
/// it's a silent runtime failure — which is why these declarations live in one
/// small file and why Task 6 tests them against a live browser.
@objc private protocol ScriptableTab {
    @objc optional var URL: String { get }
    @objc optional func executeJavascript(_ javascript: String) -> Any
}

@objc private protocol ScriptableWindow {
    @objc optional func tabs() -> SBElementArray
}

@objc private protocol ScriptableBrowser {
    @objc optional func windows() -> SBElementArray
}

/// Reads tabs out of a specific browser process.
///
/// This is the whole point of the exercise: `SBApplication(processIdentifier:)`
/// addresses one process, where `tell application "Google Chrome"` addresses
/// whichever process the system picks (ADR-0003).
final class ScriptingBridgeBrowsers: NSObject, BrowserAccess {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Apple Events time out after this many ticks of 1/60 s — 5 seconds, the
    /// same bound the AppleScript path used, so a hung browser still surfaces
    /// as a failure instead of blocking the script queue.
    private static let timeoutTicks = 5 * 60

    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab] {
        guard let app = SBApplication(processIdentifier: instance.pid) else {
            throw Failure(message: "Nie udało się połączyć z \(instance.browser.name) (proces \(instance.pid))")
        }
        let trap = ErrorTrap()
        app.delegate = trap
        app.timeout = Self.timeoutTicks
        app.sendMode = AESendMode(kAEWaitReply)

        let browser = unsafeBitCast(app, to: ScriptableBrowser.self)
        // A nil answer is not "no windows" — it's "the question didn't get
        // through". Verified with a spike: for a process that no longer exists,
        // ScriptingBridge returns nil here and never calls the delegate, so
        // trusting nil would let a dead Instance read as an empty one.
        guard let windows = browser.windows?() else {
            throw trap.failure(browser: instance.browser.name)
                ?? Failure(message: "\(instance.browser.name) nie odpowiedział na pytanie o okna")
        }

        var result: [any BrowserTab] = []
        for window in windows {
            let scriptableWindow = unsafeBitCast(window as AnyObject, to: ScriptableWindow.self)
            guard let tabs = scriptableWindow.tabs?() else { continue }
            for tab in tabs {
                let scriptableTab = unsafeBitCast(tab as AnyObject, to: ScriptableTab.self)
                guard let url = scriptableTab.URL else { continue }
                result.append(ScriptingBridgeTab(tab: scriptableTab, url: url, trap: trap, browser: instance.browser.name))
            }
        }
        if let failure = trap.failure(browser: instance.browser.name) { throw failure }
        return result
    }
}

/// One tab, reached through ScriptingBridge.
private struct ScriptingBridgeTab: BrowserTab {
    fileprivate let tab: ScriptableTab
    let url: String
    fileprivate let trap: ErrorTrap
    let browser: String

    func execute(_ javascript: String) throws -> String {
        trap.reset()
        let answer = tab.executeJavascript?(javascript)
        if let failure = trap.failure(browser: browser) { throw failure }
        guard let text = answer as? String else {
            // The same posture the AppleScript runner takes: a missing string
            // is an anomaly, not an answer. Returning "NONE" here would let a
            // browser with JavaScript-from-Apple-Events disabled masquerade as
            // a browser with no call in it.
            throw ScriptingBridgeBrowsers.Failure(
                message: "\(browser) nie zwrócił wyniku JavaScriptu — sprawdź "
                    + "View → Developer → Allow JavaScript from Apple Events"
            )
        }
        return text
    }
}

/// Catches Apple Event failures, which ScriptingBridge otherwise swallows.
///
/// Without this, revoked Automation permission would surface as a nil answer,
/// i.e. as "no call in progress" — a failure wearing the mask of a correct
/// reading, which this codebase treats as the worst possible outcome.
private final class ErrorTrap: NSObject, SBApplicationDelegate {
    private var lastError: (any Error)?

    func reset() { lastError = nil }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lastError = error
        return nil
    }

    /// Translates the trapped error into the app's own failure type, naming the
    /// two causes worth telling apart by hand: `-1743` is refused Automation
    /// permission, `-600`/`-609` mean the process went away mid-question.
    func failure(browser: String) -> ScriptingBridgeBrowsers.Failure? {
        guard let lastError else { return nil }
        let code = (lastError as NSError).code
        switch code {
        case -1743:
            return .init(message: "Brak zgody na sterowanie \(browser) — włącz ją w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja")
        case -600, -609:
            return .init(message: "\(browser) przestał działać w trakcie sprawdzania")
        default:
            return .init(message: "\(browser): błąd Apple Events \(code)")
        }
    }
}
