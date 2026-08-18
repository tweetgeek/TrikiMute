import CoreBluetooth
import Foundation
import TrikiMuteCore

/// Device state as seen by the app.
enum DeviceState: Equatable {
    case disconnected
    case searching
    /// Between a deliberate disconnect (`disconnectIdle()`) and the pending
    /// `connect()` being re-armed — see `SleepWait` and
    /// `TrikiConnection`'s sleep-wait section. Distinct from `.searching`
    /// (which also means "not connected, waiting for a press") because a
    /// press during `.fallingAsleep` does nothing yet: there is no
    /// connection for a press to reach. The menu must say so plainly rather
    /// than reuse `.searching`'s wording, which would wrongly imply a press
    /// right now re-arms it.
    case fallingAsleep
    case armed
    case error(String)
}

/// Maintains the connection to the device and turns its stream into button
/// events.
///
/// Two ways a connection comes up:
/// - **Saved device.** The identifier is in `UserDefaults`. A sleeping
///   device doesn't advertise itself over the air, so the app has no way to
///   connect to it on its own initiative. Instead of scanning continuously,
///   we remember the identifier and hold a pending `connect()`;
///   CoreBluetooth brings the connection up on its own as soon as the
///   device speaks up. The first press after a cold start wakes the device
///   and establishes the connection — and by definition doesn't trigger an
///   Action, because at the moment of the press the app wasn't listening
///   yet.
/// - **No saved device.** The app does not connect to anything on its own —
///   it waits for `startPairing()`. That scans and reports candidates via
///   `onCandidates` instead of connecting; the caller shows a list, the
///   user picks one with `choose(_:)`, and only once that choice is
///   confirmed (by a physical button-press count, handled outside this
///   type) does `confirmPairing()` persist the identifier.
///
/// A third path exists for going the other direction: `disconnectIdle()`
/// deliberately tears the connection down again (idle timeout or the
/// "Uśpij Kapsel" menu action), and — unlike an ordinary loss of range —
/// does *not* immediately re-arm the pending `connect()` afterward. See the
/// "Sleep wait" section below for why an immediate re-arm defeated the
/// point of disconnecting at all.
@MainActor
final class TrikiConnection: NSObject {
    private enum UUIDs {
        static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let battery = CBUUID(string: "180F")
        static let batteryLevel = CBUUID(string: "2A19")
    }

    /// Command that starts the IMU stream. Without it the device stays
    /// silent, and button state is embedded in the IMU frame header — it
    /// can't be read separately.
    private static let startCommand = Data([0x20, 0x10, 0x00, 0xD0, 0x07, 0x68, 0x00, 0x03])
    private static let knownDeviceKey = "znanyKapselUUID"
    // Filtered from the nonisolated `didDiscover` callback, before hopping
    // to the main actor — a plain immutable String constant is safe to read
    // from any isolation domain, but the compiler can't infer that for a
    // static member of a @MainActor type without this annotation.
    private nonisolated static let nameFragment = "triki"

    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((DeviceState) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?
    var onCandidates: (([DeviceCandidate]) -> Void)?

    /// Typed as the narrow `CentralManaging` seam, not `CBCentralManager`,
    /// so pairing's ordering invariants can be driven directly in tests. See
    /// `CentralManaging`'s doc comment.
    private var central: (any CentralManaging)!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var parser = FrameParser()
    private var recognizer = ButtonRecognizer()

    /// Non-nil for the duration of pairing — from `startPairing()` until
    /// either `confirmPairing()` or `cancelPairing()` ends it.
    private var pairing: PairingSession?

    /// State scoped to one pairing attempt. `candidates` is keyed by
    /// identifier so a repeat advertisement updates signal strength instead
    /// of duplicating. `chosen` is set once `choose(_:)` picks one of them.
    /// Restoring what was there before pairing (the saved device's pending
    /// connection, if any) doesn't need a captured reference — `UserDefaults`
    /// is never written during pairing, so `resumeSearch()` re-reading it
    /// after the fact is sufficient and avoids a second source of truth.
    private struct PairingSession {
        var candidates: [UUID: (info: DeviceCandidate, peripheral: CBPeripheral)] = [:]
        var chosen: CBPeripheral?
    }

    /// Set by `disconnectIdle()` immediately before it asks `central` to
    /// disconnect, and consumed by the very next `didDisconnectPeripheral`
    /// callback for the current peripheral. Distinguishes a disconnect this
    /// app asked for from any other loss of connection (out of range, a
    /// radio hiccup): only a deliberate one enters the sleep wait below — an
    /// ordinary drop still re-arms immediately, exactly as before this
    /// feature existed.
    private var deliberateDisconnectPending = false

    /// Non-nil for the duration of the wait between a deliberate disconnect
    /// and the pending `connect()` being re-armed. See `SleepWait` and the
    /// "Sleep wait" section below.
    private var sleepWait: SleepWait?
    private var sleepWaitBurstEndTimer: Timer?
    private var sleepWaitNextBurstTimer: Timer?
    private var sleepWaitCapTimer: Timer?

    /// How long one scan burst runs. The Kapsel advertised readily and
    /// continuously throughout every pairing scan in this codebase's own
    /// testing — nothing suggests a sparse advertising interval — so a
    /// four-second window is generous for catching it if it's still there,
    /// without holding the radio scanning long enough to matter for power.
    private static let sleepWaitBurstDuration: TimeInterval = 4.0

    /// Time from the start of one burst to the start of the next. A fifth
    /// of that (4s of 20s, 20% duty cycle) is scanning; the rest is idle —
    /// "short bursts rather than continuously," matching the design brief.
    /// The device takes roughly three minutes to actually fall asleep
    /// (measured: `docs/findings/2026-08-12-kapsel.md`), so checking every
    /// 20 seconds notices the transition within a small fraction of that
    /// window without scanning nearly as much as continuous scanning would.
    private static let sleepWaitBurstInterval: TimeInterval = 20.0

    /// Overall bound on the wait, independent of the burst rhythm above.
    /// 270s (4.5 minutes) is comfortably past the measured ~180s — about 50%
    /// margin for the fact that "about 180 seconds" was one measurement, not
    /// a guaranteed constant. If the device never goes quiet (including
    /// because a press kept it awake — see `SleepWait`'s doc on why that's a
    /// feature, not a gap), this is what re-arms the pending connect anyway,
    /// so this state can never be gotten stuck in forever — the same
    /// "bound everything" posture `AppState`'s pairing timeouts already take.
    private static let sleepWaitCap: TimeInterval = 270.0

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Test seam: injects a fake `CentralManaging` directly, skipping
    /// `start()`'s real `CBCentralManager` construction — there is no real
    /// central manager to start against in a unit test, and no delegate
    /// callbacks will arrive from a fake, so nothing here needs one.
    /// Production code always goes through the no-argument initializer (via
    /// `TrikiConnection()`) and calls `start()`.
    convenience init(central: any CentralManaging) {
        self.init()
        self.central = central
    }

    /// Whether a device identifier is currently saved — independent of
    /// whether that device is reachable right now. See the protocol doc
    /// comment on `DeviceConnection.hasSavedDevice` for why the menu needs
    /// this instead of reading `DeviceState`.
    var hasSavedDevice: Bool {
        UserDefaults.standard.string(forKey: Self.knownDeviceKey) != nil
    }

    /// Requests a signal strength reading. The answer arrives asynchronously
    /// in `peripheral(_:didReadRSSI:error:)`.
    func readRSSI() {
        peripheral?.readRSSI()
    }

    /// Forgets the device and goes back to waiting. Use when there's nothing
    /// to replace it with — a lost or given-away capsule — as opposed to
    /// `startPairing()`, which replaces the saved device with another one.
    /// The app won't reconnect until `startPairing()` is called again:
    /// `resumeSearch()` at the end of this method is not a contradiction —
    /// by the time it runs, `knownDeviceKey` has already been cleared above,
    /// so it finds nothing saved and does nothing. That's deliberate, not
    /// incidental: forgetting must leave the app idle rather than
    /// immediately hunting for the very device it was just told to forget,
    /// and calling `resumeSearch()` here (instead of duplicating its "leave
    /// `.disconnected`" ending) is what makes that fall out for free.
    ///
    /// Also ends any pairing session in progress: `central` — and therefore
    /// the scan invariant (never left running with nothing able to stop it)
    /// — belongs solely to this type, so it has to hold regardless of what
    /// a caller does, not merely because the menu is expected to prevent
    /// calling this mid-pairing. Stopping the scan and clearing `pairing`
    /// before tearing down the connection also means `resumeSearch()`'s own
    /// `guard pairing == nil` never blocks the (already-inert) call at the
    /// end of this method.
    func forget() {
        cancelSleepWait()
        UserDefaults.standard.removeObject(forKey: Self.knownDeviceKey)
        if pairing != nil {
            central.stopScan()
            pairing = nil
        }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        onState?(.disconnected)
        resumeSearch()
    }

    /// Ends the live connection for the sake of battery, without forgetting
    /// the device or giving up on it: the saved identifier is left
    /// untouched, and — critically — so is `peripheral`. That's what makes
    /// this the mirror image of `forget()` rather than a duplicate of it:
    /// `forget()` clears `peripheral` *before* disconnecting specifically so
    /// `didDisconnectPeripheral`'s staleness guard suppresses the automatic
    /// reconnect; here the guard is left free to fire, so the very next
    /// `didDisconnectPeripheral` callback sees `deliberateDisconnectPending`
    /// and enters the sleep wait below instead of re-arming immediately —
    /// see the "Sleep wait" section for why an immediate re-arm defeated the
    /// whole point of disconnecting (a real Kapsel keeps advertising for
    /// about 180 seconds after this call, so an immediate `connect()`
    /// reconnected it within a fraction of a second and resumed the stream).
    ///
    /// Called by `AppState` from two places that both boil down to "let the
    /// Kapsel sleep now": its idle policy (`checkIdleDeadline()`, no Meet
    /// Target for `AppState.idleTimeout`), and the "Uśpij Kapsel" menu
    /// action (`sleepDevice()`), triggered by hand instead of by a clock.
    /// Both call this exact same method — there is no separate "manual
    /// disconnect" path — so the two are guaranteed to behave identically;
    /// only the trigger differs, and both therefore go through the same
    /// sleep wait afterward. There is no documented command that puts
    /// the Kapsel to sleep on request — TrikiScope only ever documented the
    /// stream's start command — so disconnecting is the reliable
    /// substitute, for either trigger: with nothing connected, the device
    /// stops transmitting and (once the sleep wait confirms it) sleeps on
    /// its own, exactly as it does whenever the app isn't running at all.
    /// Measured in the field under the previous always-connected policy:
    /// 98%→90% overnight, roughly twelve days of standby for hardware that
    /// should idle for weeks (see `docs/follow-ups.md`).
    ///
    /// Guards on `pairing == nil` defensively, same posture as the other
    /// methods here — `AppState` only calls this while its own pairing phase
    /// is `.inactive`, but nothing about this type's own invariants should
    /// depend on a caller remembering that.
    func disconnectIdle() {
        guard pairing == nil, let peripheral else { return }
        deliberateDisconnectPending = true
        central.cancelPeripheralConnection(peripheral)
    }

    /// Enters discovery mode: clears any previous candidate list and starts
    /// scanning. Leaves the saved identifier and the current `peripheral`
    /// (if any) untouched — a saved device already connecting or connected
    /// keeps running undisturbed while the user browses candidates.
    ///
    /// `pairing != nil` guards against a reentrant call: `AppState` already
    /// refuses to call this while its own `pairing` phase is live, but this
    /// type owns `central` and `pairing`'s bookkeeping (`candidates`,
    /// `chosen`), so it — not a well-behaved caller — is what has to hold
    /// the invariant that a session in progress is never silently replaced.
    /// A reentrant call here would reset `pairing` to an empty session and
    /// drop `chosen`, which `cancelPairing()` reads to decide whether to
    /// disconnect a connected candidate and restore the saved device; with
    /// `chosen` gone, it would take the wrong branch. Same reasoning Task
    /// 2's review applied to `confirmPairing()` and `forget()`.
    ///
    /// Returns `false` without doing anything if Bluetooth isn't powered on
    /// or a session is already live — a silent no-op here previously left
    /// `AppState` announcing a search that wasn't actually running (final
    /// review, Issue 1). The Bluetooth-not-ready case doesn't need its own
    /// message: `centralManagerDidUpdateState` already reports the specific
    /// cause via `onState(.error(...))` whenever the state changes, so
    /// `AppState.deviceState` already holds it by the time this refuses.
    ///
    /// Also leaves an in-progress sleep wait (see the "Sleep wait" section
    /// below) — a session starting here must not be able to arrive at
    /// `.deviceIsGone`/`.capExpired` mid-pairing and issue a stray
    /// `resumeSearch()` underneath the candidate the user is actively
    /// choosing between.
    @discardableResult
    func startPairing() -> Bool {
        guard central?.state == .poweredOn, pairing == nil else { return false }
        cancelSleepWait()
        pairing = PairingSession()
        central.scanForPeripherals(withServices: nil, options: nil)
        return true
    }

    /// Stops scanning, connects to the chosen candidate, and lets it run the
    /// normal service-discovery path to `.armed`. If a previous peripheral
    /// (the saved device) was connected or pending, it's disconnected first
    /// — `peripheral` is reassigned before that disconnect is requested, so
    /// the guard in `didDisconnectPeripheral` recognizes it as stale and
    /// doesn't try to reconnect it.
    func choose(_ id: UUID) {
        guard var session = pairing, let candidate = session.candidates[id]?.peripheral else { return }
        central.stopScan()
        let previous = peripheral
        peripheral = candidate
        candidate.delegate = self
        if let previous, previous.identifier != candidate.identifier {
            central.cancelPeripheralConnection(previous)
        }
        session.chosen = candidate
        pairing = session
        central.connect(candidate, options: nil)
        onState?(.searching)
    }

    /// Aborts pairing and restores exactly the state from before
    /// `startPairing()`. Two cases:
    /// - Still collecting (no `choose(_:)` yet): `peripheral` was never
    ///   touched, so there's nothing to undo — a saved device's connection
    ///   (if any) kept running the whole time.
    /// - A candidate was chosen: disconnect it and, if there was a
    ///   previous (saved) peripheral, resume its pending connection via
    ///   `resumeSearch()`; if there wasn't one, settle on `.disconnected`.
    func cancelPairing() {
        guard let session = pairing else { return }
        central.stopScan()
        pairing = nil
        guard let chosen = session.chosen else { return }
        central.cancelPeripheralConnection(chosen)
        peripheral = nil
        rx = nil
        onState?(.disconnected)
        resumeSearch()
    }

    /// Persists the identifier of `pairing.chosen` — the candidate
    /// `choose(_:)` actually picked — as the remembered device. Deliberately
    /// not `peripheral`: that tracks whatever the connection layer currently
    /// has live, which during a `.connecting` reconnect race can momentarily
    /// point somewhere other than the confirmed choice. `chosen` is set once,
    /// by `choose(_:)`, and never reassigned — it's the only value that
    /// actually answers "which device did the user pick," which is the
    /// entire point of pairing (final review, Issue 2).
    ///
    /// Requires an active session with a chosen candidate; returns `false`
    /// and persists nothing otherwise, so a caller can't accidentally
    /// announce success for a device that was never confirmed. The only
    /// place that writes `knownDeviceKey`: `didDiscover` no longer does, and
    /// `choose(_:)` only connects, so an unconfirmed candidate can never
    /// become "the" device.
    ///
    /// Stops the scan defensively, same as `cancelPairing()`: the expected
    /// caller only confirms after `choose(_:)` already stopped it, but
    /// nothing here should depend on being called in the right order —
    /// called out of sequence, this must still leave the scan invariant
    /// intact rather than end the session with scanning still running and
    /// no way left to stop it.
    @discardableResult
    func confirmPairing() -> Bool {
        guard let session = pairing, let chosen = session.chosen else { return false }
        central.stopScan()
        UserDefaults.standard.set(chosen.identifier.uuidString, forKey: Self.knownDeviceKey)
        pairing = nil
        return true
    }

    /// Known device: a pending `connect()`. No saved device: does nothing —
    /// the app waits for `startPairing()` rather than connecting to
    /// anything on its own.
    ///
    /// Refuses outright while a pairing session is live (`pairing != nil`).
    /// Without this, a Bluetooth power-cycle mid-pairing could reassign
    /// `peripheral` to the saved device while `pairing.chosen` still points
    /// at the candidate — hijacking the session (final review, Issue 3).
    /// `handleCentralStateChange(_:)` already avoids calling this in that
    /// case, but the guard belongs here too: nothing about correctness
    /// should depend on every future caller remembering to check first.
    private func resumeSearch() {
        guard pairing == nil else { return }
        guard central?.state == .poweredOn else { return }
        guard let saved = UserDefaults.standard.string(forKey: Self.knownDeviceKey),
              let uuid = UUID(uuidString: saved),
              let known = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return
        }
        onState?(.searching)
        peripheral = known
        known.delegate = self
        central.connect(known, options: nil)
    }

    private func resetRecognition() {
        parser = FrameParser()
        recognizer = ButtonRecognizer()
    }

    // MARK: - Sleep wait
    //
    // After a deliberate disconnect (`disconnectIdle()`), the Kapsel keeps
    // advertising for a while before it actually falls asleep — measured on
    // real hardware at roughly 180 seconds
    // (`docs/findings/2026-08-12-kapsel.md`). Re-arming the pending
    // `connect()` immediately reconnected it within a fraction of a second
    // and resumed the stream, defeating the disconnect entirely — the
    // defect this section fixes. Instead, `didDisconnectPeripheral` routes a
    // deliberate disconnect through `startSleepWait()`, which scans in short
    // bursts for the saved identifier specifically (not just any
    // "triki"-named device) and only re-arms once a burst finds it gone, or
    // once `sleepWaitCap` protects against a device that never disappears —
    // including one kept awake by a button press during the wait, which is
    // deliberately allowed to fall through to the cap rather than hang (see
    // `SleepWait`'s doc).
    //
    // The decision logic itself lives in `SleepWait`, pure and fully unit
    // tested without CoreBluetooth. Everything here is orchestration: real
    // `Timer`s in production, but every step is also a directly callable,
    // package-visible method — the same pattern `AppState`'s
    // `checkXDeadline()` methods use — so `TrikiConnectionTests` can drive
    // the whole wait deterministically.

    /// Starts the wait for the saved device to actually stop advertising,
    /// following a deliberate disconnect — see the section doc above.
    ///
    /// Reads the saved identifier fresh from `UserDefaults` rather than
    /// reusing `peripheral`'s identifier: "match the saved identifier
    /// specifically" is the point (another capsule advertising nearby says
    /// nothing about this one), and reading it fresh here is also what lets
    /// tests call this method directly without a real `CBPeripheral` — the
    /// same trick `resumeSearch()`'s own tests already rely on.
    ///
    /// If nothing is saved — shouldn't happen in practice, since this is
    /// only ever reached right after disconnecting a peripheral that came
    /// from a saved identifier — there's nothing to wait for: report
    /// `.disconnected` directly instead of starting a wait with no target.
    func startSleepWait() {
        guard let saved = UserDefaults.standard.string(forKey: Self.knownDeviceKey),
              let uuid = UUID(uuidString: saved) else {
            onState?(.disconnected)
            return
        }
        sleepWait = SleepWait(identifier: uuid)
        onState?(.fallingAsleep)
        beginSleepWaitBurst()
        sleepWaitCapTimer?.invalidate()
        sleepWaitCapTimer = Timer.scheduledTimer(withTimeInterval: Self.sleepWaitCap, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSleepWaitCapDeadline() }
        }
    }

    /// Feeds one discovery into the active sleep wait, if any — a harmless
    /// no-op otherwise (nothing being watched, or the identifier doesn't
    /// match — see `SleepWait.sighted(_:)`). Split out from `didDiscover` so
    /// it's callable directly with a plain identifier, no real
    /// `CBPeripheral` required, matching this file's established seam for
    /// what can and can't be driven from a unit test.
    func handleSleepWaitSighting(identifier: UUID) {
        sleepWait?.sighted(identifier)
    }

    /// Starts one scan burst: marks a fresh burst in `sleepWait`, starts
    /// scanning, and schedules `endSleepWaitBurst()` after
    /// `sleepWaitBurstDuration`. A no-op if no wait is active.
    func beginSleepWaitBurst() {
        guard sleepWait != nil else { return }
        sleepWait?.burstStarted()
        central.scanForPeripherals(withServices: nil, options: nil)
        sleepWaitBurstEndTimer?.invalidate()
        sleepWaitBurstEndTimer = Timer.scheduledTimer(withTimeInterval: Self.sleepWaitBurstDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.endSleepWaitBurst() }
        }
    }

    /// Ends the current scan burst and judges it via `SleepWait.burstEnded()`:
    /// if the watched identifier was never sighted, the wait concludes —
    /// `concludeSleepWait()` stops the scan in that case, so this doesn't
    /// stop it twice. Otherwise this stops the burst's scan itself and
    /// schedules the next burst after the remaining gap
    /// (`sleepWaitBurstInterval - sleepWaitBurstDuration`) — the "short
    /// bursts rather than continuously" rhythm: scanning pauses for the gap,
    /// not just between the end of one burst and the judgment above. A
    /// no-op if no wait is active (already concluded, or never started).
    func endSleepWaitBurst() {
        guard sleepWait != nil else { return }
        sleepWait?.burstEnded()
        if sleepWait?.outcome != nil {
            concludeSleepWait()
            return
        }
        central.stopScan()
        sleepWaitNextBurstTimer?.invalidate()
        let gap = Self.sleepWaitBurstInterval - Self.sleepWaitBurstDuration
        sleepWaitNextBurstTimer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.beginSleepWaitBurst() }
        }
    }

    /// Evaluates whether the overall cap has passed, without waiting on the
    /// real `sleepWaitCapTimer` — same directly-callable, deterministic
    /// pattern `AppState`'s `checkXDeadline()` methods use for their own
    /// one-shot bounds. Concludes the wait unconditionally once it fires,
    /// even mid-burst (see `SleepWait.capElapsed()`). A no-op if no wait is
    /// active.
    func checkSleepWaitCapDeadline() {
        guard sleepWait != nil else { return }
        sleepWait?.capElapsed()
        if sleepWait?.outcome != nil {
            concludeSleepWait()
        }
    }

    /// Tears down the sleep wait's timers and scan, then re-arms the
    /// pending connect via the exact same `resumeSearch()` an ordinary
    /// reconnect already uses — no separate "reconnect after sleep wait"
    /// path to keep in sync with it. Reached once `SleepWait.outcome` is
    /// non-nil, from either `endSleepWaitBurst()` or
    /// `checkSleepWaitCapDeadline()`.
    private func concludeSleepWait() {
        sleepWaitBurstEndTimer?.invalidate()
        sleepWaitBurstEndTimer = nil
        sleepWaitNextBurstTimer?.invalidate()
        sleepWaitNextBurstTimer = nil
        sleepWaitCapTimer?.invalidate()
        sleepWaitCapTimer = nil
        central.stopScan()
        sleepWait = nil
        resumeSearch()
    }

    /// Cancels an in-progress sleep wait without concluding it — used when
    /// something else needs to take over: starting a fresh pairing session
    /// (`startPairing()`) or forgetting the device (`forget()`). Leaves the
    /// state at `.disconnected`; whichever caller invoked this reports
    /// whatever comes next on its own (a fresh scan for pairing,
    /// `resumeSearch()` finding nothing for `forget()` since the identifier
    /// is cleared before this runs). A no-op if no wait is active.
    private func cancelSleepWait() {
        guard sleepWait != nil else { return }
        sleepWaitBurstEndTimer?.invalidate()
        sleepWaitBurstEndTimer = nil
        sleepWaitNextBurstTimer?.invalidate()
        sleepWaitNextBurstTimer = nil
        sleepWaitCapTimer?.invalidate()
        sleepWaitCapTimer = nil
        central.stopScan()
        sleepWait = nil
        onState?(.disconnected)
    }

    /// Reacts to a Bluetooth power/authorization change. Split out from the
    /// `CBCentralManagerDelegate` callback (which hands it a real
    /// `CBCentralManager` the tests can't fake) so it can be exercised
    /// directly and deterministically — see `CentralManaging`.
    ///
    /// Guards `.poweredOn`: with a pairing session live, restarts the scan
    /// instead of resuming the saved device's connection. Before this guard,
    /// a power-cycle mid-pairing called `resumeSearch()` unconditionally,
    /// which during `.searching` never restarted the scan CoreBluetooth had
    /// just dropped (the candidate list would sit empty forever), and during
    /// a chosen candidate's connection reassigned `peripheral` to the saved
    /// device while `pairing.chosen` still pointed at the candidate —
    /// hijacking the session onto the wrong device (final review, Issue 3).
    /// Restarting the scan is safe regardless of how far the session has
    /// gotten: `didDiscover` only ever updates `pairing.candidates`, never
    /// `peripheral` or `central.connect`, and `AppState` only acts on
    /// `onCandidates` while its own phase is `.searching` (see `didDiscover`'s
    /// comment) — so a stray rediscovery during `.connecting`/`.confirming`
    /// is inert.
    ///
    /// Same reasoning extends to an in-progress sleep wait: CoreBluetooth
    /// already drops any live scan on `.poweredOff`, but `sleepWait` itself
    /// (and its `Timer`s) survive the round trip untouched. Resuming the
    /// interrupted burst — rather than falling through to `resumeSearch()`
    /// — keeps a stray power cycle from re-arming the pending connect early
    /// and reproducing the exact defect this whole feature exists to fix.
    func handleCentralStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            if pairing != nil {
                central.scanForPeripherals(withServices: nil, options: nil)
            } else if sleepWait != nil {
                beginSleepWaitBurst()
            } else {
                resumeSearch()
            }
        case .poweredOff: onState?(.error("Bluetooth jest wyłączony"))
        case .unauthorized: onState?(.error("Brak zgody na Bluetooth"))
        case .unsupported: onState?(.error("Ten Mac nie obsługuje Bluetooth LE"))
        default: onState?(.disconnected)
        }
    }
}

extension TrikiConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in handleCentralStateChange(state) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard name.lowercased().contains(Self.nameFragment) else { return }
        let rssi = RSSI.intValue
        Task { @MainActor in
            // Outside pairing, discovery does nothing — no saved device
            // means the app waits for the user to start pairing, and it
            // never connects or writes UserDefaults on its own.
            //
            // `stopScan()` in `choose(_:)` doesn't suppress in-flight
            // discoveries synchronously, so a stray one can still land
            // here after a candidate was chosen. That's harmless: this
            // only ever updates `pairing.candidates`, never `self.peripheral`
            // or `central.connect`, so a late discovery can't overwrite or
            // reconnect the chosen device.
            if var session = pairing {
                session.candidates[peripheral.identifier] = (
                    DeviceCandidate(id: peripheral.identifier, name: name, rssi: rssi),
                    peripheral
                )
                pairing = session
                let sorted = session.candidates.values.map(\.info).sorted { $0.rssi > $1.rssi }
                onCandidates?(sorted)
            }
            // Pairing and a sleep wait never run at the same time —
            // `startPairing()` cancels any wait first — but feeding this
            // unconditionally costs nothing: `handleSleepWaitSighting`
            // itself no-ops when no wait is active.
            handleSleepWaitSighting(identifier: peripheral.identifier)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            resetRecognition()
            peripheral.discoverServices([UUIDs.nus, UUIDs.battery])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            // Deliberate disconnect: `choose(_:)`, `cancelPairing()`, or
            // `forget()` already reassigned/cleared `peripheral` before this
            // callback arrived — e.g. `choose(_:)` disconnecting a previously
            // connected saved device in favor of the newly chosen candidate,
            // or `forget()` clearing `peripheral` before its own
            // `cancelPeripheralConnection` call resolves. Without this guard,
            // a stale disconnect for that no-longer-current peripheral would
            // immediately reconnect it — for `forget()` specifically, that
            // would resurrect a connection (and a "searching" state) for the
            // very device the user just asked the app to forget.
            guard peripheral.identifier == self.peripheral?.identifier else { return }
            rx = nil
            if deliberateDisconnectPending {
                // `disconnectIdle()` asked for this disconnect — don't
                // re-arm the pending connect yet. See the "Sleep wait"
                // section: the device stays advertising for a while after
                // this, and reconnecting immediately would resume the
                // stream and defeat the whole point of disconnecting.
                deliberateDisconnectPending = false
                startSleepWait()
            } else {
                onState?(.disconnected)
                // The pending connect() will bring the connection back up once
                // the device returns.
                central.connect(peripheral, options: nil)
                onState?(.searching)
            }
        }
    }
}

extension TrikiConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { @MainActor in
                onState?(.error("Nie udało się odczytać usług: \(error.localizedDescription)"))
            }
            return
        }
        Task { @MainActor in
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let serviceUUID = service.uuid
        if let error {
            // A failure on the battery service doesn't disable the app; a
            // failure on NUS means there will be no stream.
            if serviceUUID == UUIDs.nus {
                Task { @MainActor in
                    onState?(.error("Nie udało się odczytać charakterystyk: \(error.localizedDescription)"))
                }
            }
            return
        }
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case UUIDs.tx:
                    // The start command is sent only after subscription is
                    // confirmed, in didUpdateNotificationStateFor.
                    peripheral.setNotifyValue(true, for: ch)
                case UUIDs.rx:
                    rx = ch
                case UUIDs.batteryLevel:
                    peripheral.readValue(for: ch)
                    peripheral.setNotifyValue(true, for: ch)
                default:
                    break
                }
            }
        }
    }

    /// Subscription confirmation. Only here do we know the stream has a way
    /// to arrive — so only here do we send the start command and announce
    /// Arming.
    ///
    /// The order in which CoreBluetooth returns characteristics isn't
    /// guaranteed. Announcing Arming on discovery of RX could therefore fire
    /// before the app had subscribed to TX — i.e. declare readiness for a
    /// connection that had no way to deliver anything.
    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let enabled = characteristic.isNotifying
        if let error {
            if uuid == UUIDs.tx {
                Task { @MainActor in
                    onState?(.error("Nie udało się włączyć strumienia: \(error.localizedDescription)"))
                }
            }
            return
        }
        guard uuid == UUIDs.tx, enabled else { return }
        Task { @MainActor in
            guard let rx else {
                onState?(.error("Brak charakterystyki do wysłania komendy startowej"))
                return
            }
            peripheral.writeValue(Self.startCommand, for: rx, type: .withoutResponse)
            onState?(.armed)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let value = RSSI.intValue
        Task { @MainActor in onRSSI?(value) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let bytes = [UInt8](data)
        // The wall clock (Date()) isn't monotonic — a clock going backwards
        // (waking from a long sleep, an NTP correction, a manual time
        // change) would produce negative gaps, and ButtonRecognizer would
        // reject every edge as contact bounce until the clock "caught up"
        // with the previous timestamps. systemUptime always increases, so
        // the gaps between samples stay reliable regardless of system clock
        // changes.
        let now = ProcessInfo.processInfo.systemUptime

        Task { @MainActor in
            switch uuid {
            case UUIDs.batteryLevel:
                if let level = bytes.first { onBattery?(Int(level)) }
            case UUIDs.tx:
                for sample in parser.consume(bytes, at: now) {
                    if let event = recognizer.consume(sample) {
                        onEvent?(event)
                    }
                }
            default:
                break
            }
        }
    }
}
