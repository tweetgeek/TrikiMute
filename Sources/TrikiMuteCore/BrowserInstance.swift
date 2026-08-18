import Foundation

/// A browser the app knows how to control.
///
/// One list, two uses: the bundle identifier is how running processes are
/// recognized, the name is what AppleScript addresses and what the menu shows.
/// Keeping both in one type is deliberate — a third browser must never mean
/// remembering to edit two separate lists.
public struct SupportedBrowser: Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A single running browser process.
///
/// Not a profile: several profiles share one Instance, and only separate
/// processes are separate Instances (see `CONTEXT.md`). This distinction is the
/// whole reason this type exists — an Instance is what an Apple Event can be
/// addressed to, and what a browser name cannot distinguish.
public struct BrowserInstance: Equatable, Sendable {
    public let pid: pid_t
    public let browser: SupportedBrowser
    /// Whether this process is the frontmost application.
    public let isActive: Bool

    public init(pid: pid_t, browser: SupportedBrowser, isActive: Bool) {
        self.pid = pid
        self.browser = browser
        self.isActive = isActive
    }
}

/// The order in which Instances are searched for a Target.
public enum BrowserOrdering {
    /// Every browser the app can control, in preference order.
    public static let supported: [SupportedBrowser] = [
        SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser"),
    ]

    /// Sorts Instances by three keys, in order: the active one first, then the
    /// order browsers appear in `supported`, then ascending pid.
    ///
    /// The third key isn't decoration. `NSWorkspace.runningApplications` makes
    /// no promise about ordering, so without it the same arrangement of windows
    /// could pick a different Target after a restart, with nothing having
    /// changed for the user. It also tends to put the instance a human started
    /// in the morning ahead of one a tool started later, which is exactly the
    /// failure this work exists to fix.
    public static func ordered(
        _ instances: [BrowserInstance],
        supported: [SupportedBrowser]
    ) -> [BrowserInstance] {
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:`: this is a
        // public function, and a crash is a poor failure mode for something
        // whose whole job is determinism. `supported` having a duplicated
        // `bundleID` is unreachable from today's call sites, but if it ever
        // happened, keeping the first (lowest, i.e. most-preferred) rank is
        // the same tie-break this function already applies elsewhere.
        let rank = Dictionary(
            supported.enumerated().map { ($1.bundleID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return instances.sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            let leftRank = rank[left.browser.bundleID] ?? Int.max
            let rightRank = rank[right.browser.bundleID] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.pid < right.pid
        }
    }
}
