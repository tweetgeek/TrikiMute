import Foundation

/// Decides when it's safe to re-arm the pending `connect()` after a
/// deliberate disconnect (manual sleep or the idle timeout).
///
/// The Kapsel keeps advertising for a while after being disconnected —
/// measured on real hardware at roughly 180 seconds
/// (`docs/findings/2026-08-12-kapsel.md`) — before it actually falls asleep
/// and goes quiet. Re-arming the pending `connect()` immediately after the
/// disconnect (the previous behavior) reconnects to the still-advertising
/// device within a fraction of a second, which resumes the IMU stream and
/// defeats the whole point of disconnecting. This type tracks, in pure
/// logic, whether the specific device we just disconnected has actually
/// gone quiet, so the caller (`TrikiConnection`) knows when it's safe to
/// re-arm.
///
/// Driven by three kinds of events, none of which read a clock or touch
/// CoreBluetooth directly — the caller owns the actual scanning/timers and
/// tells this type what happened:
/// - `sighted(_:)` — a discovery callback saw some device; only a sighting
///   matching `identifier` counts.
/// - `burstEnded()` — one scan burst finished. If `identifier` was never
///   sighted during that burst, the device is presumed gone.
/// - `capElapsed()` — the overall bound passed. Concludes regardless of
///   whether the device was still being sighted — see the type-level doc on
///   `TrikiConnection`'s cap for why an unbounded wait is unacceptable here,
///   and for the pleasant side effect this produces: a device kept awake by
///   a button press during the wait never disappears, so the cap is what
///   arms it.
///
/// Once `outcome` is set, every further call is a no-op — the first
/// conclusion wins, and nothing here regresses it.
public struct SleepWait: Equatable {
    public enum Outcome: Equatable, Sendable {
        /// A scan burst ended without seeing `identifier` — the device has
        /// gone quiet. Safe to re-arm the pending connect.
        case deviceIsGone
        /// The cap elapsed before the device ever disappeared. Re-arm
        /// anyway rather than wait forever — this is also what makes a
        /// press during the wait "win": it keeps the device advertising, so
        /// it never triggers `.deviceIsGone`, and the cap is what finally
        /// arms it.
        case capExpired
    }

    /// The device identifier this wait is watching for — the saved
    /// identifier, specifically, not just any device whose name matches.
    /// Another capsule advertising nearby must not influence this wait.
    public let identifier: UUID

    public private(set) var outcome: Outcome?

    /// Whether `identifier` has been sighted during the scan burst
    /// currently in progress. Reset at the start of each burst by the
    /// caller — see `TrikiConnection.beginSleepWaitBurst()` — not by this
    /// type, since only the caller knows when a new burst actually starts.
    private var sawDeviceThisBurst = false

    public init(identifier: UUID) {
        self.identifier = identifier
    }

    /// Records a discovery. Sightings of any identifier other than the one
    /// being watched are irrelevant — a different capsule advertising
    /// nearby says nothing about whether *this* one has gone to sleep.
    public mutating func sighted(_ seenIdentifier: UUID) {
        guard outcome == nil, seenIdentifier == identifier else { return }
        sawDeviceThisBurst = true
    }

    /// Marks the start of a fresh burst — clears the "seen this burst" flag
    /// so `burstEnded()` judges only sightings from the burst that's about
    /// to run, not a stale one from an earlier burst.
    public mutating func burstStarted() {
        sawDeviceThisBurst = false
    }

    /// One scan burst just finished. If `identifier` was never sighted
    /// during it, the device is presumed asleep.
    public mutating func burstEnded() {
        guard outcome == nil else { return }
        if !sawDeviceThisBurst {
            outcome = .deviceIsGone
        }
        sawDeviceThisBurst = false
    }

    /// The overall cap elapsed. Concludes the wait unconditionally, even
    /// mid-burst — see the type-level doc for why an unbounded wait isn't
    /// acceptable.
    public mutating func capElapsed() {
        guard outcome == nil else { return }
        outcome = .capExpired
    }
}
