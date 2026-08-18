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

        /// Maps an Apple Event error code to the message shown to the user.
        ///
        /// Pure mapping, extracted out of `ErrorTrap` so it can be tested
        /// without a real browser process — it's the one piece of genuinely
        /// testable logic in a file whose whole reason for existing is that
        /// the rest cannot be. Named by hand: `-1743` is refused Automation
        /// permission, `-600`/`-609` mean the process went away mid-question.
        static func appleEvent(code: Int, browser: String) -> Failure {
            switch code {
            case -1743:
                return .init(message: "Brak zgody na sterowanie \(browser) — włącz ją w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja")
            case -600, -609:
                return .init(message: "\(browser) przestał działać w trakcie sprawdzania")
            default:
                return .init(message: "\(browser): błąd Apple Events \(code)")
            }
        }

        /// Validates the raw return value of `executeJavascript:`, extracted
        /// out of `ScriptingBridgeTab.execute` so the mandatory "JavaScript
        /// from Apple Events disabled" case can be tested without a real
        /// browser process.
        ///
        /// A missing string is an anomaly, not an answer — the same posture
        /// the AppleScript runner takes. Returning "NONE" here would let a
        /// browser with JavaScript-from-Apple-Events disabled masquerade as a
        /// browser with no call in it.
        static func validated(_ answer: Any?, browser: String) throws -> String {
            guard let text = answer as? String else {
                throw Failure(
                    message: "\(browser) nie zwrócił wyniku JavaScriptu — sprawdź "
                        + "View → Developer → Allow JavaScript from Apple Events"
                )
            }
            return text
        }

        /// The sweep decision, extracted out of `tabs(in:)` so the most
        /// dangerous logic in this file — the one thing standing between a
        /// swallowed Apple Event and a false `.noTarget` — can be tested
        /// without building real ScriptingBridge objects.
        ///
        /// Generic over the payload: production calls this with
        /// `Element == (tab: ScriptableTab, url: String)` so the collected
        /// values are ready to become `ScriptingBridgeTab`s directly; tests
        /// call it with `Element == String`, standing in for just the URL.
        ///
        /// `windows` is one entry per window that was asked for its tabs —
        /// `nil` if the window itself didn't answer `tabs()`. A non-nil entry
        /// is that window's tabs, one per tab, `nil` if that tab didn't
        /// answer `URL`.
        ///
        /// A `nil` is swallowed silently as long as *something* elsewhere in
        /// the sweep answered: one non-answering window or tab must not take
        /// down an Instance whose other windows/tabs answered normally. But
        /// if literally nothing answered — every entry `nil` — an empty
        /// result would read as "no call in this browser", i.e. a failure
        /// wearing the mask of `.noTarget`, so that case throws instead of
        /// returning empty.
        static func sweep<Element>(_ windows: [[Element?]?], browser: String) throws -> [Element] {
            var result: [Element] = []
            var unanswered = false
            for window in windows {
                guard let tabs = window else {
                    unanswered = true
                    continue
                }
                for element in tabs {
                    guard let element else {
                        unanswered = true
                        continue
                    }
                    result.append(element)
                }
            }
            if result.isEmpty && unanswered {
                throw Failure(message: "\(browser) nie odpowiedział na pytanie o karty")
            }
            return result
        }
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

        // Below the window level, a nil answer is only lenient in the case
        // that has an innocent explanation. There are two gates, not one:
        //
        // - If the nil came from an actual Apple Event *error* — the trap
        //   caught something — `trap.failure(browser:)` below is non-nil and
        //   the whole Instance throws unconditionally, regardless of the
        //   `nil`s collected here. A window that failed to answer because the
        //   event itself errored is exactly what the trap records, so it can
        //   never survive as a quiet skip.
        // - If the nil came from `respondsToSelector:` simply returning false
        //   for that particular object (a DevTools panel, some other window
        //   ScriptingBridge can't fully describe) — no error, nothing for the
        //   trap to see — then it really is a class the app cannot ask, and
        //   it's swallowed by `Failure.sweep` below: it must not take down an
        //   Instance whose other windows answered normally.
        //
        // `Failure.sweep` is the backstop for the case where neither of those
        // fired conclusively (see its doc comment for the empty-sweep rule).
        var perWindow: [[(tab: ScriptableTab, url: String)?]?] = []
        for window in windows {
            let scriptableWindow = unsafeBitCast(window as AnyObject, to: ScriptableWindow.self)
            guard let tabs = scriptableWindow.tabs?() else {
                perWindow.append(nil)
                continue
            }
            var windowTabs: [(tab: ScriptableTab, url: String)?] = []
            for tab in tabs {
                let scriptableTab = unsafeBitCast(tab as AnyObject, to: ScriptableTab.self)
                if let url = scriptableTab.URL {
                    windowTabs.append((scriptableTab, url))
                } else {
                    windowTabs.append(nil)
                }
            }
            perWindow.append(windowTabs)
        }
        if let failure = trap.failure(browser: instance.browser.name) { throw failure }
        let collected = try Failure.sweep(perWindow, browser: instance.browser.name)
        return collected.map { ScriptingBridgeTab(tab: $0.tab, url: $0.url, trap: trap, browser: instance.browser.name) }
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
        return try ScriptingBridgeBrowsers.Failure.validated(answer, browser: browser)
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

    /// Translates the trapped error into the app's own failure type via
    /// `ScriptingBridgeBrowsers.Failure.appleEvent(code:browser:)`.
    func failure(browser: String) -> ScriptingBridgeBrowsers.Failure? {
        guard let lastError else { return nil }
        let code = (lastError as NSError).code
        return ScriptingBridgeBrowsers.Failure.appleEvent(code: code, browser: browser)
    }
}
