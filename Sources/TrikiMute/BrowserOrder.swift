import AppKit

/// Order in which browsers are polled. The one on top goes first — if you
/// have two calls open, the one you're actually looking at wins.
enum BrowserOrder {
    static let all = ["Google Chrome", "Brave Browser"]

    /// Application names for AppleScript, with the frontmost browser first.
    static func ordered() -> [String] {
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName,
              all.contains(frontmost) else {
            return all
        }
        return [frontmost] + all.filter { $0 != frontmost }
    }
}
