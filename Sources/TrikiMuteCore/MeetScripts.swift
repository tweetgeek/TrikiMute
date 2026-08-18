import Foundation

/// Scripts that control the Google Meet call.
///
/// Meet has no API, and a synthetic keyboard shortcut won't work because
/// shortcut handling only reacts to trusted events — so we click the actual
/// button in the DOM instead. This is the only place in the code where DOM
/// selectors are allowed to appear.
public enum MeetScripts {
    /// The attribute used to recognize the microphone and camera buttons.
    /// Deliberately not `aria-label` — that label is translated and would
    /// drift out of sync with a change of interface language.
    public static let buttonSelector = "[data-is-muted]"

    /// Button positions in the `querySelectorAll` result. Values confirmed
    /// by the Task 1 spike (`docs/findings/2026-08-12-meet-dom.md`).
    public static let micIndex = 0
    public static let cameraIndex = 1

    /// JS fragment shared by the probe and the action. Returns `NONE` when
    /// the tab doesn't have a full set of buttons — that's the signal for
    /// "no target".
    private static let preamble = """
    var b=document.querySelectorAll('\(buttonSelector)');if(b.length<2)return 'NONE';
    """

    /// Returns two characters: microphone and camera state, where 1 means off.
    public static func probeJS() -> String {
        """
        (function(){\(preamble)\
        var f=function(e){return e.getAttribute('data-is-muted')==='true'?'1':'0'};\
        return f(b[\(micIndex)])+f(b[\(cameraIndex)])})()
        """
    }

    /// Clicks the button matching the action. Returns `OK` or `NONE`.
    public static func toggleJS(_ action: MeetAction) -> String {
        let index = action == .microphone ? micIndex : cameraIndex
        return """
        (function(){\(preamble)\
        b[\(index)].click();return 'OK'})()
        """
    }

    /// Escapes text inserted into an AppleScript string literal.
    /// Without this, a quote would break the string, and a backslash would
    /// get consumed by AppleScript before JavaScript ever saw it.
    /// Order matters: backslashes first, then quotes.
    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Wraps the JS in a script that searches for the Target among a given
    /// browser's tabs. The tab doesn't need to be active or frontmost —
    /// that's the whole point of using Apple Events instead of a keyboard
    /// shortcut.
    ///
    /// Both inserted texts are escaped, so the function is correct for
    /// arbitrary input rather than just for generators that stick to
    /// apostrophes.
    /// A browser hung on `execute … javascript` would block the script
    /// queue up to AppleScript's default 60-second limit. This timeout
    /// brings that down to 5 seconds, so a hung browser surfaces as
    /// `.failed` (and an audible `Basso`) instead of a silent stall.
    public static func appleScript(browser: String, javascript: String) -> String {
        """
        tell application "\(escaped(browser))"
            with timeout of 5 seconds
                if it is not running then return "NONE"
                repeat with w in windows
                    repeat with t in tabs of w
                        if URL of t contains "meet.google.com" then
                            set result to execute t javascript "\(escaped(javascript))"
                            if result is not "NONE" then return result
                        end if
                    end repeat
                end repeat
            end timeout
        end tell
        return "NONE"
        """
    }
}
