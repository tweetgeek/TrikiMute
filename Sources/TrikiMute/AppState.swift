import Foundation
import Observation
import TrikiMuteCore

/// The state of an in-progress device pairing, driven by `AppState` and
/// switched on directly by the menu.
///
/// `searching`, `connecting`, and `confirming` all count as "a session is
/// live" — see `startPairing()`'s guard. `failed` is not live: it's a
/// terminal state the user must acknowledge (retry via `startPairing()`
/// again, or `cancelPairing()`) rather than something that clears itself, so
/// the message in it is guaranteed to still be there when the user next
/// opens the menu.
///
/// `connecting` and `confirming` are deliberately separate phases, each with
/// its own bound (see `AppState.connectTimeout` / `AppState.pressTimeout`).
/// An earlier version of this type used a single `confirming` phase entered
/// immediately on choice, with one deadline covering both connecting and
/// pressing — closing the ghost-candidate hang, but leaving a candidate that
/// connects late with too little of the press window, and showing the press
/// countdown against a device that had already dropped mid-confirmation.
/// Splitting the phase fixes both: the required press count (rolled once, in
/// `AppState.chosenRequired`) survives a drop-and-reconnect unchanged, but
/// the press clock in `confirming` only starts once the device is actually
/// Armed.
///
/// **Fix round 2, Finding 1:** splitting the phase this way traded the
/// original unbounded wait for a new one — `.confirming` falling back to
/// `.connecting` on every drop, with a *fresh* `connectTimeout` each time,
/// meant a device flapping at the edge of range could cycle indefinitely:
/// neither per-phase timer ever reached its deadline, because both kept
/// restarting. The single-deadline design this replaced was immune to that
/// specific failure, because its one timer never restarted — worth stating
/// plainly, since the fix for Finding 1 (round 1) is what opened this gap.
/// `AppState.attemptTimeout` closes it: a bound on the whole attempt,
/// started once in `choosePairingCandidate(_:)` and never reset by a
/// per-phase restart, so indefinite flapping still resolves to `.failed`.
///
/// **Fix round 2, Finding 2:** a drop also discarded whatever press progress
/// had already been counted, silently — the user could press two of three
/// and, after a drop-and-reconnect, keep believing one more press would
/// finish it. `confirming`'s third field, `resetAfterDrop`, makes the reset
/// visible in the menu instead of just correct in the model.
enum PairingPhase: Equatable {
    case inactive
    case searching([DeviceCandidate])
    case connecting(candidate: DeviceCandidate)
    case confirming(candidate: DeviceCandidate, remaining: Int, resetAfterDrop: Bool)
    case failed(String)
}

/// The single source of truth for the UI.
@MainActor
@Observable
final class AppState {
    private(set) var deviceState: DeviceState = .disconnected
    private(set) var battery: Int?
    private(set) var rssi: Int?
    private(set) var target: ProbeResult?
    /// Set when the probe couldn't check the Target at all — most commonly
    /// missing Automation permission or JavaScript execution disabled.
    /// Empty when the probe answered, even if that answer was "no Target".
    private(set) var probeError: String?
    private(set) var lastAction: String = "—"
    private(set) var loginItemError: String?
    private(set) var pairing: PairingPhase = .inactive

    private let connection: any DeviceConnection
    private let controller: MeetController
    private let scriptQueue: any ScriptQueue
    /// Source of timestamps for pairing confirmation, injected so tests can
    /// cross a deadline without sleeping. Production default is
    /// `ProcessInfo.processInfo.systemUptime`, never `Date()` — see the note
    /// on monotonic time in `TrikiConnection`.
    private let now: () -> TimeInterval
    /// Source of the browser polling order, injected so tests can supply a
    /// fixed list instead of `BrowserOrder.ordered()` reading the real
    /// `NSWorkspace.shared.frontmostApplication` — a test run with a browser
    /// frontmost would otherwise see the list reorder out from under it and
    /// fail for a reason that has nothing to do with what it's testing (see
    /// `docs/follow-ups.md`). Production default is `BrowserOrder.ordered()`,
    /// called synchronously at each call site — see the note there on why
    /// that has to happen on the main thread, before dispatching to
    /// `scriptQueue`.
    private let browserOrder: () -> [String]
    private var probeTimer: Timer?
    private var probeInFlight = false
    /// Non-nil for the duration of `.confirming`. Owns the press count and
    /// the deadline for the candidate currently being confirmed. `nil` during
    /// `.connecting` — there is nothing to count presses against yet.
    private var confirmation: PairingConfirmation?
    /// The press count rolled once, in `choosePairingCandidate(_:)`, for the
    /// candidate currently being paired. Lives across `.connecting` and
    /// `.confirming` — including a drop-and-reconnect round trip between the
    /// two — so the number the user was told never changes mid-flow.
    /// `nil` outside an active `.connecting`/`.confirming` session.
    private var chosenRequired: Int?
    /// Fires once, at `searchTimeout`, so an abandoned `.searching` session —
    /// the menu dismissed without cancelling, nothing ever chosen — resolves
    /// to `.failed` instead of leaving `TrikiConnection` scanning
    /// indefinitely with the Meet probe suppressed the whole time (final
    /// review, Issue 4). Retired by `choosePairingCandidate(_:)`, whose own
    /// `connectTimer` takes over once something has actually been chosen.
    /// Live only during `.searching`.
    private var searchTimer: Timer?
    /// Fires once, at `connectTimeout`, so a candidate that never arms — the
    /// ghost-candidate case (it stopped advertising and `connect()` never
    /// calls back), or an ordinary drop mid-confirmation whose reconnect
    /// never completes — still resolves to `.failed` instead of leaving
    /// `.connecting` waiting forever. Live only during `.connecting`.
    private var connectTimer: Timer?
    /// Fires once, at `pressTimeout`, so a candidate that arms but never
    /// receives enough presses resolves to `.failed` instead of leaving
    /// `.confirming` waiting forever. A press reaching the deadline first is
    /// handled by `consume(_:at:)` directly; this timer is only needed for
    /// the no-more-presses case. Live only during `.confirming`.
    private var pressTimer: Timer?
    /// Fires once, at `attemptTimeout`, started in `choosePairingCandidate(_:)`
    /// and — unlike `connectTimer`/`pressTimer` — never reset by a
    /// `.confirming` ↔ `.connecting` round trip. Closes the flapping gap
    /// (fix round 2, Finding 1): a device dropping and reconnecting faster
    /// than either per-phase timer's deadline can otherwise cycle
    /// indefinitely, since both restart on every transition. This timer's
    /// clock keeps running through all of that, so the whole attempt still
    /// resolves to `.failed` within a bounded total time.
    private var attemptTimer: Timer?
    /// Set when `.confirming` falls back to `.connecting` after a drop (see
    /// the `onState` handler), and read when `.connecting` promotes back to
    /// `.confirming` on the next arming — so that `.confirming`'s
    /// `resetAfterDrop` field reflects whether *this* attempt has already
    /// lost press progress at least once. Reset to `false` at the start of
    /// every new attempt in `choosePairingCandidate(_:)`.
    private var droppedDuringAttempt = false
    /// Action in flight. Presses that arrive before the previous Action
    /// returns from the queue are dropped, not queued — a stale toggle,
    /// executed with a delay after a burst of presses, is worse than not
    /// executing at all. Real-world trigger: first launch, where a blocked
    /// Automation permission dialog piles up presses in the queue, and they
    /// all fire at once the moment the user clicks "Allow".
    private var actionInFlight = false
    /// A probe requested while another was in flight. It isn't lost — it
    /// runs right after the current one finishes.
    private var probePending = false
    /// Probe generation number. A result from a stale generation is
    /// ignored: disconnecting bumps the number, so a response sent before
    /// the disconnect won't write back data for a device that's no longer
    /// there.
    private var probeGeneration = 0

    /// Deadline (on the injected `now()` clock) after which the device is
    /// allowed to sleep — `nil` while there's nothing to watch, i.e.
    /// whenever `stopProbing()` runs (not Armed, or a pairing session is
    /// live). Restarted by `resetIdleClock()` on any evidence someone is
    /// around: the device just Armed, the probe found a Target, or a button
    /// event reached `perform(_:)`. Unlike the pairing timers'
    /// `checkXDeadline()` methods — which are one-shot and never reset
    /// mid-phase, so being called at all is equivalent to "the deadline
    /// passed" — this deadline is reset far more often than it fires, so
    /// `checkIdleDeadline()` has to compare against `now()` itself rather
    /// than trust its caller.
    private var idleDeadline: TimeInterval?

    /// Probe interval. The probe only runs while the device is Armed —
    /// outside of a call there's nothing to poll.
    private static let probeInterval: TimeInterval = 3.0

    /// How long the device may stay Armed with no Meet Target before the
    /// app disconnects it deliberately, so it can sleep. The button state
    /// lives in the header of the IMU frames, and the stream only starts
    /// after the start command — so an Armed device has to transmit
    /// continuously (~106 frames/second) for the app to have any chance of
    /// seeing a press, and there is no documented command that puts it back
    /// to sleep on request. Measured in the field under the previous
    /// always-connected policy: 98%→90% battery overnight, roughly twelve
    /// days of standby for hardware that should idle for weeks (see
    /// `docs/follow-ups.md`). Disconnecting is the reliable substitute for a
    /// sleep command: with nothing connected the device stops transmitting
    /// and sleeps on its own, and the arming model already holds a pending
    /// `connect()` that picks it back up the instant a press wakes it — see
    /// `TrikiConnection.disconnectIdle()`. 10 minutes is generous enough
    /// that a long meeting where nobody presses anything never trips it
    /// (every Target sighting resets the clock — see `refreshTarget()`), but
    /// still short enough to matter for a capsule left Armed and forgotten.
    /// Not `private`: `AppStateTests` crosses it deliberately via the
    /// injected clock.
    static let idleTimeout: TimeInterval = 600.0

    /// How long `.searching` scans before giving up if nothing is chosen.
    /// The Kapsel doesn't advertise until its button is pressed, so this has
    /// to be generous enough for someone to notice the empty list, walk
    /// over, and press it — but scanning isn't free (final review, Issue 4):
    /// left unbounded, dismissing the menu without cancelling kept
    /// `TrikiConnection` scanning indefinitely, with the Meet probe
    /// suppressed the entire time. 2 minutes is well past what a deliberate
    /// pairing attempt needs, while still resolving an abandoned menu in
    /// bounded time. Not `private`: `AppStateTests` crosses it deliberately.
    static let searchTimeout: TimeInterval = 120.0

    /// Not `private`, for the same reason as the other failure messages.
    static let searchFailureMessage = "Nie znaleziono żadnego Kapsla w wyznaczonym czasie."

    /// How long a chosen candidate has to reach Armed before pairing gives
    /// up on it — covers both the initial connect and any reconnect after a
    /// mid-confirmation drop (`.confirming` falls back to `.connecting` on
    /// disconnect; see the `onState` handler). 10s is generous for a BLE
    /// connect plus service discovery on a device that's actually there;
    /// past that, it isn't coming. Not `private`: `AppStateTests` crosses it
    /// deliberately via the injected clock.
    static let connectTimeout: TimeInterval = 10.0

    /// How long the user has to complete the press count once the candidate
    /// is Armed. Starts fresh every time `.confirming` is entered — after
    /// the initial arming and after any reconnect — so a slow connection
    /// never eats into press time. 15s comfortably covers the maximum of 5
    /// presses at a deliberate human pace. Not `private`: `AppStateTests`
    /// crosses it deliberately via the injected clock.
    static let pressTimeout: TimeInterval = 15.0

    /// Distinct failure messages for the two bounds, so the user is told
    /// which one actually happened rather than reading a message that
    /// doesn't match what occurred — the class of defect Finding 1 (fix
    /// round 1) exists to remove. Not `private`, for the same reason as the
    /// timeouts above.
    static let connectFailureMessage = "Kapsel nie odpowiedział w wyznaczonym czasie."
    static let pressFailureMessage = "Nie potwierdzono wyboru w wyznaczonym czasie — spróbuj ponownie."

    /// Overall bound on one pairing attempt, from `choosePairingCandidate(_:)`
    /// to a conclusion (confirmed, cancelled, or any failure) — independent
    /// of how many times `connectTimer`/`pressTimer` individually restart.
    /// Fix round 2, Finding 1: closes the flapping gap the round 1 split
    /// opened (see the type-level comment on `PairingPhase`).
    ///
    /// One honest connect-plus-press cycle is at most `connectTimeout +
    /// pressTimeout` = 25s. 60s is comfortably more than double that —
    /// enough room for one legitimate drop-and-reconnect without failing a
    /// merely slow connection, while still bounding indefinite flapping to
    /// a wait a user will actually tolerate. Not `private`, for the same
    /// reason as the other timeouts.
    static let attemptTimeout: TimeInterval = 60.0

    /// Names the real cause — repeated drops, not a single slow step — so
    /// the user isn't told "didn't respond" or "didn't press enough" for a
    /// failure that was neither. Not `private`, for the same reason as the
    /// other messages.
    static let flappingFailureMessage = "Kapsel wielokrotnie się rozłączał podczas parowania — spróbuj ponownie."

    /// Scripts run off the main thread. `NSAppleScript` blocks for the
    /// duration of the exchange with the browser, and on first use also for
    /// the duration of the user's answer to the permission prompt — on the
    /// main thread that would freeze the menu bar. The queue is serial, so
    /// the probe and Actions don't step on each other. State is only mutated
    /// after returning to the main thread.
    ///
    /// `connection`, `controller`, `scriptQueue`, `now`, and `browserOrder`
    /// are initializer parameters solely so that tests can substitute doubles
    /// for real CoreBluetooth, AppleScript, background threads, wall-clock
    /// time, and `NSWorkspace`. The defaults reproduce the existing
    /// production wiring, so `AppState()` in `TrikiMuteApp.swift` doesn't need
    /// to change.
    ///
    /// `connection` defaults to `nil` rather than `TrikiConnection()`
    /// directly: parameter default expressions don't inherit the
    /// initializer's `@MainActor` isolation, so constructing `TrikiConnection`
    /// (a `@MainActor` class) has to happen in the body of `init`, not in its
    /// parameter list.
    init(
        connection: (any DeviceConnection)? = nil,
        controller: MeetController = MeetController(runner: AppleScriptRunner()),
        scriptQueue: any ScriptQueue = DefaultScriptQueue(
            backgroundQueue: DispatchQueue(label: "pl.tweetgeek.trikimute.skrypty")
        ),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        browserOrder: @escaping () -> [String] = { BrowserOrder.ordered() }
    ) {
        let connection = connection ?? TrikiConnection()
        self.connection = connection
        self.controller = controller
        self.scriptQueue = scriptQueue
        self.now = now
        self.browserOrder = browserOrder
        connection.onState = { [weak self] state in
            guard let self else { return }
            deviceState = state
            // Fresh evidence the device is actually reachable — restart the
            // idle-sleep countdown from here regardless of pairing phase.
            // `stopProbing()` (via `updateProbing()` below) clears it again
            // for every non-Armed state, so a stale reset from a background
            // saved device can't outlive its own connection.
            if state == .armed { resetIdleClock() }
            switch pairing {
            case .connecting(let candidate):
                // Only Armed advances the phase — .disconnected/.searching/
                // .error while still connecting just means the bound hasn't
                // been reached yet; connectTimer is already running and
                // covers all of them uniformly.
                if state == .armed, let required = chosenRequired {
                    pairing = .confirming(candidate: candidate, remaining: required, resetAfterDrop: droppedDuringAttempt)
                    startPressTimer(required: required)
                }
            case .confirming(let candidate, _, _):
                // The connection dropped before confirmation finished.
                // TrikiConnection already re-issues a pending connect() on
                // its own (see didDisconnectPeripheral) — this just gives
                // that reconnect attempt a fresh, bounded .connecting window
                // instead of leaving a press countdown on screen against a
                // device that's no longer there (Finding 1, fix round 1).
                // chosenRequired is untouched, so a later re-arm resumes
                // with the same required count — but the presses already
                // counted are discarded (a dropped connection confirmed
                // nothing), and droppedDuringAttempt records that this
                // happened, so the next .confirming visibly says the count
                // restarted (Finding 2, fix round 2) instead of silently
                // resetting. attemptTimer is deliberately left running —
                // that's the whole point of Finding 1's fix.
                if state != .armed {
                    confirmation = nil
                    droppedDuringAttempt = true
                    pairing = .connecting(candidate: candidate)
                    startConnectTimer()
                }
            case .inactive, .searching, .failed:
                break
            }
            updateProbing()
        }
        connection.onBattery = { [weak self] in self?.battery = $0 }
        connection.onRSSI = { [weak self] in self?.rssi = $0 }
        connection.onEvent = { [weak self] event in
            guard let self else { return }
            switch pairing {
            case .confirming:
                // Only the confirming phase intercepts presses — while
                // merely browsing candidates (.searching) or waiting to
                // connect (.connecting), a saved device that's still
                // connected keeps controlling Meet exactly as before pairing
                // started (see the "change device" note on startPairing()).
                if var pending = confirmation {
                    let outcome = pending.consume(event, at: self.now())
                    confirmation = pending
                    handlePairingOutcome(outcome)
                }
            case .connecting:
                // No legitimate press can arrive here: the candidate isn't
                // Armed yet, and choose() already disconnected whatever was
                // previously connected. An event reaching this branch would
                // be unexpected — drop it rather than let it either count
                // toward a confirmation that doesn't exist yet or fire an
                // Action for an unconfirmed device.
                break
            case .inactive, .searching, .failed:
                // A genuine button event reaching the currently-controlled
                // device — as opposed to a press consumed by
                // `PairingConfirmation` for a different, not-yet-confirmed
                // candidate — is exactly the kind of activity the idle
                // policy exists to not disconnect through.
                resetIdleClock()
                perform(event == .press ? .microphone : .camera)
            }
        }
        connection.onCandidates = { [weak self] candidates in
            guard let self, case .searching = pairing else { return }
            pairing = .searching(candidates)
        }
        connection.start()
    }

    /// SF Symbol name for the menu bar icon.
    ///
    /// Pairing gets its own symbol, checked before `deviceState` — `updateProbing()`
    /// suppresses the probe for the entire pairing session, including while
    /// merely browsing candidates with a previously saved device still
    /// connected and Armed in the background. Without this, the icon kept
    /// showing `mic.fill`/`mic.slash.fill` — asserting live mic state the app
    /// had no way to actually know during pairing (final review, Issue 4).
    var iconName: String {
        guard pairing == .inactive else { return "antenna.radiowaves.left.and.right" }
        switch deviceState {
        case .error: return "exclamationmark.triangle"
        case .disconnected, .searching: return "circle.dotted"
        case .armed:
            if probeError != nil { return "exclamationmark.triangle" }
            return target?.micMuted == true ? "mic.slash.fill" : "mic.fill"
        }
    }

    var deviceDescription: String {
        switch deviceState {
        case .disconnected: return "Kapsel rozłączony"
        case .searching: return "Szukam Kapsla — naciśnij przycisk, żeby go obudzić"
        case .armed: return "Kapsel uzbrojony"
        case .error(let message): return message
        }
    }

    var targetDescription: String {
        if let probeError { return "Nie mogę sprawdzić Celu: \(probeError)" }
        guard let target else { return "Brak Celu — nie ma czego wyciszyć" }
        return "\(target.browser): mikrofon \(target.micMuted ? "wyciszony" : "aktywny"), "
            + "kamera \(target.cameraOff ? "wyłączona" : "włączona")"
    }

    var loginItemDescription: String {
        switch LoginItem.status {
        case .enabled: return "✓ Uruchamiaj przy logowaniu"
        case .disabled: return "Uruchamiaj przy logowaniu"
        case .requiresApproval: return "Uruchamiaj przy logowaniu — zatwierdź w Ustawieniach"
        }
    }

    func perform(_ action: MeetAction) {
        guard !actionInFlight else {
            // Silence here would reproduce exactly the class of defect this
            // branch eliminates: a press has to be audibly acknowledged even
            // when it gets dropped.
            let outcome = ActionOutcome.failed("poprzednia Akcja jeszcze trwa, pominięto")
            Feedback.play(outcome)
            lastAction = describe(action, outcome)
            return
        }
        actionInFlight = true
        // NSWorkspace is still queried on the main thread here (in production;
        // see the `browserOrder` doc comment for the injected-default shape).
        let browsers = browserOrder()
        let controller = self.controller
        scriptQueue.run(
            background: { controller.perform(action, browsers: browsers) },
            main: { [weak self] outcome in
                guard let self else { return }
                actionInFlight = false
                Feedback.play(outcome)
                lastAction = describe(action, outcome)
                // Meet updates the DOM asynchronously after the click — the
                // read has to wait, otherwise we'd see the state from before
                // the Action.
                scriptQueue.afterDelay(0.3) { [weak self] in
                    self?.refreshTarget()
                }
            }
        )
    }

    func toggleLoginItem() {
        loginItemError = LoginItem.toggle()
    }

    /// Enters or restarts discovery: clears the candidate list and starts
    /// scanning. This is the menu's entry point for *replacing* the saved
    /// device — with none saved it's the first pairing, with one already
    /// saved it's "Zmień Kapsla". `forgetDevice()` is the complementary
    /// entry point for *removing* it with nothing to replace it with. The
    /// previously saved device, if any, keeps working undisturbed until a
    /// new one is actually confirmed — see `choosePairingCandidate(_:)` and
    /// `TrikiConnection.startPairing()`.
    ///
    /// Guards against two cases: a session already `.searching`,
    /// `.connecting`, or `.confirming` is left alone rather than silently
    /// replaced (a second call would otherwise discard a chosen candidate's
    /// bookkeeping while its connection stayed live — flagged in Task 2's
    /// review). A `.failed` phase, by contrast, is not live — this is also
    /// how the menu's "back to the list" action re-enters discovery after a
    /// timeout.
    func startPairing() {
        switch pairing {
        case .searching, .connecting, .confirming: return
        case .inactive, .failed: break
        }
        guard connection.startPairing() else {
            // Land on the actual cause instead of announcing a search that
            // isn't running (final review, Issue 1). The Bluetooth-not-ready
            // causes are already named in `deviceState` — `onState(.error(...))`
            // fires synchronously on every CoreBluetooth state change, so by
            // the time `startPairing()` can refuse for that reason,
            // `deviceState` already holds the specific message. The fallback
            // covers the one CBManagerState this app doesn't treat as an
            // error (`.unknown`/`.resetting`, mapped to `.disconnected`).
            if case .error(let message) = deviceState {
                pairing = .failed(message)
            } else {
                pairing = .failed("Bluetooth jeszcze się nie uruchomił — spróbuj za chwilę.")
            }
            updateProbing()
            return
        }
        pairing = .searching([])
        startSearchTimer()
        updateProbing()
    }

    /// Whether a device identifier is currently saved. Drives the menu's
    /// pairing button label — deliberately not keyed off `deviceState`,
    /// which can be `.error` (e.g. Bluetooth off) even though a device is
    /// saved and would otherwise show "Paruj Kapsla" for a device that only
    /// needs Bluetooth back, not a first-time pairing (final review, Issue 1).
    var hasSavedDevice: Bool { connection.hasSavedDevice }

    /// Picks a candidate from the current list and connects to it. Rolls the
    /// required press count exactly once, here — it survives unchanged into
    /// `.confirming`, and across any drop-and-reconnect, via `chosenRequired`.
    ///
    /// **Ghost-candidate hang (Task 2 review):** `connect()` has no timeout
    /// of its own, and a capsule that stopped advertising mid-scan can still
    /// be sitting in `candidates` — chosen, its connection would otherwise
    /// hang forever with the app stuck on "searching". `pairing` moves to
    /// `.connecting` immediately and `startConnectTimer()` bounds it: if the
    /// candidate never arms, `checkConnectDeadline()` fails pairing with
    /// `connectFailureMessage` regardless of whether the candidate is gone or
    /// just slow. The `onState` handler is what promotes `.connecting` to
    /// `.confirming` once the device actually arms — see its comment for the
    /// symmetric case of a drop after that point.
    ///
    /// **Fix round 1 (Finding 1):** an earlier version skipped `.connecting`
    /// entirely and started the press clock at the moment of choice, so a
    /// candidate that took most of the connect budget to arm left the user
    /// almost no time to press, and a connect-timeout and a press-timeout
    /// were indistinguishable to the user. Splitting the phase here fixes
    /// both — see the type-level comment on `PairingPhase`.
    ///
    /// The alternative the brief offered for the hang — evicting candidates
    /// that stop advertising — was not implemented: the brief's own note
    /// that a bound is required either way (the device can still vanish
    /// between the list being drawn and the row being clicked) makes it
    /// strictly additional complexity in `TrikiConnection`, not a substitute
    /// for the bound.
    ///
    /// **Fix round 2:** also starts `attemptTimer` — the overall bound on
    /// this whole attempt, independent of the `.connecting`/`.confirming`
    /// round trips a flapping device can cause (see the type-level comment
    /// on `PairingPhase`) — and resets `droppedDuringAttempt`, since this is
    /// a fresh attempt with no drops yet.
    func choosePairingCandidate(_ id: UUID) {
        guard case .searching(let candidates) = pairing,
              let candidate = candidates.first(where: { $0.id == id }) else { return }
        searchTimer?.invalidate()
        searchTimer = nil
        connection.choose(id)
        chosenRequired = PairingConfirmation.randomRequirement()
        confirmation = nil
        droppedDuringAttempt = false
        pairing = .connecting(candidate: candidate)
        updateProbing()
        startConnectTimer()
        startAttemptTimer()
    }

    /// Aborts pairing at any phase and restores whatever was connected
    /// before `startPairing()` — a no-op if nothing is in progress.
    ///
    /// `pairing` is assigned *before* calling into `connection` (final
    /// review, Issue 5): `TrikiConnection.cancelPairing()` emits
    /// `onState(.disconnected)` synchronously once a candidate had been
    /// chosen, and the old order called `connection.cancelPairing()` while
    /// `pairing` was still `.confirming` — so the reentrant `onState` handler
    /// took the drop-and-reconnect branch and scheduled a fresh
    /// `connectTimer` *after* this function's own invalidation had already
    /// run, leaking a live timer underneath a teardown that was supposed to
    /// leave none running. Setting `pairing` first means that by the time the
    /// synchronous callback checks it, it already reads `.inactive`, so the
    /// reentrant branch is never taken at all.
    func cancelPairing() {
        guard pairing != .inactive else { return }
        searchTimer?.invalidate()
        searchTimer = nil
        attemptTimer?.invalidate()
        attemptTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        pressTimer?.invalidate()
        pressTimer = nil
        confirmation = nil
        chosenRequired = nil
        droppedDuringAttempt = false
        pairing = .inactive
        connection.cancelPairing()
        updateProbing()
    }

    /// Clears the saved device and returns the app to idle — no pending
    /// connection, no live session, nothing to hunt for. The complement to
    /// `startPairing()`: that lets the saved device be *replaced*, this lets
    /// it be *removed* with nothing to replace it with — the case
    /// `startPairing()` doesn't cover, e.g. a lost or given-away capsule.
    /// Menu-visible only when `hasSavedDevice` is true (see `MenuBarView`),
    /// but not guarded here on `pairing` being `.inactive`: like
    /// `cancelPairing()`, it has to be coherent no matter what phase it's
    /// called from, not merely because the menu is expected to only offer it
    /// at rest.
    ///
    /// Tears down any live pairing session first, using the same
    /// timer/bookkeeping reset as `cancelPairing()` — `connection.forget()`
    /// independently defends its own scan invariant regardless of caller
    /// (see its doc comment), but it knows nothing about `AppState`'s own
    /// timers or `chosenRequired`/`confirmation`, so those still need
    /// clearing here. `pairing` is assigned to `.inactive` *before* calling
    /// into `connection`, same reasoning as `cancelPairing()` (final review,
    /// Issue 5): `TrikiConnection.forget()` always emits
    /// `onState(.disconnected)` synchronously, and by the time that reentrant
    /// callback checks `pairing` it must already read `.inactive` — otherwise
    /// the `onState` handler's `.confirming` branch would treat it as an
    /// ordinary mid-confirmation drop and schedule a fresh `connectTimer`
    /// underneath a teardown that was supposed to leave none running.
    func forgetDevice() {
        searchTimer?.invalidate()
        searchTimer = nil
        attemptTimer?.invalidate()
        attemptTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        pressTimer?.invalidate()
        pressTimer = nil
        confirmation = nil
        chosenRequired = nil
        droppedDuringAttempt = false
        pairing = .inactive
        connection.forget()
        updateProbing()
    }

    /// True while none of the pairing timers is currently scheduled. Exists
    /// solely for `AppStateTests` to confirm a teardown path didn't leave a
    /// timer running underneath a `pairing` value that has already moved past
    /// it (final review, Issue 5) — `pairing` alone can't reveal that: every
    /// teardown path's final assignment lands on the right value regardless
    /// of whether a timer leaked underneath it.
    var hasNoLivePairingTimers: Bool {
        searchTimer == nil && attemptTimer == nil && connectTimer == nil && pressTimer == nil
    }

    /// Starts the bound on `.searching` finding nothing and nobody choosing
    /// anything. Retired by `choosePairingCandidate(_:)`, whose own
    /// `connectTimer` takes over from there.
    private func startSearchTimer() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: Self.searchTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkSearchDeadline() }
        }
    }

    /// Starts the overall bound on one pairing attempt, once, from
    /// `choosePairingCandidate(_:)`. Deliberately not called from
    /// `startConnectTimer()`/`startPressTimer()` — restarting it on every
    /// phase transition would recreate the exact flapping gap it exists to
    /// close (fix round 2, Finding 1).
    private func startAttemptTimer() {
        attemptTimer?.invalidate()
        attemptTimer = Timer.scheduledTimer(withTimeInterval: Self.attemptTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAttemptDeadline() }
        }
    }

    /// Starts (or restarts) the bound on getting the chosen candidate
    /// connected and Armed. Invalidates any running `pressTimer` — the two
    /// timers are mutually exclusive, one per live phase. Deliberately does
    /// not touch `attemptTimer`.
    private func startConnectTimer() {
        pressTimer?.invalidate()
        pressTimer = nil
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: Self.connectTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkConnectDeadline() }
        }
    }

    /// Starts the press-count bound, fresh, once the candidate is Armed.
    /// Invalidates `connectTimer` — its job is done for this arming.
    /// Deliberately does not touch `attemptTimer`.
    private func startPressTimer(required: Int) {
        connectTimer?.invalidate()
        connectTimer = nil
        confirmation = PairingConfirmation(required: required, timeout: Self.pressTimeout, startedAt: now())
        pressTimer?.invalidate()
        pressTimer = Timer.scheduledTimer(withTimeInterval: Self.pressTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPressDeadline() }
        }
    }

    /// Applies the outcome of feeding the `PairingConfirmation` a press or a
    /// deadline check. Shared by the press path (`onEvent`) and the timer
    /// path (`checkPressDeadline()`) so both end up in exactly the same
    /// place.
    private func handlePairingOutcome(_ outcome: PairingConfirmation.Outcome) {
        switch outcome {
        case .pending(let remaining):
            if case .confirming(let candidate, _, let resetAfterDrop) = pairing {
                pairing = .confirming(candidate: candidate, remaining: remaining, resetAfterDrop: resetAfterDrop)
            }
        case .confirmed:
            attemptTimer?.invalidate()
            attemptTimer = nil
            pressTimer?.invalidate()
            pressTimer = nil
            confirmation = nil
            chosenRequired = nil
            droppedDuringAttempt = false
            // confirmPairing() can refuse (no active session, or one with no
            // chosen candidate) — a caller has to be able to tell that apart
            // from success instead of announcing confirmation unconditionally
            // for a device that was never actually saved (final review,
            // Issue 2). In today's code the guard that reaches `.confirmed`
            // at all already guarantees a chosen candidate exists, so this
            // path isn't expected to be hit — but the whole point of the
            // identity invariant is not depending on that staying true.
            if connection.confirmPairing() {
                pairing = .inactive
            } else {
                pairing = .failed("Nie udało się zapisać wybranego Kapsla — spróbuj ponownie.")
            }
            updateProbing()
        case .timedOut:
            attemptTimer?.invalidate()
            attemptTimer = nil
            pressTimer?.invalidate()
            pressTimer = nil
            confirmation = nil
            chosenRequired = nil
            droppedDuringAttempt = false
            // `pairing` assigned before calling into `connection` (final
            // review, Issue 5) — see the comment on `cancelPairing()` for why
            // the old order let a synchronous `onState(.disconnected)` leak a
            // timer past this teardown.
            pairing = .failed(Self.pressFailureMessage)
            // Tears down the unconfirmed candidate and restores the
            // previously saved device's suspended connection, if there was
            // one — same restoration `cancelPairing()` relies on.
            connection.cancelPairing()
            updateProbing()
        }
    }

    private func describe(_ action: MeetAction, _ outcome: ActionOutcome) -> String {
        let co = action == .microphone ? "Mikrofon" : "Kamera"
        switch outcome {
        case .performed: return "\(co): przełączono"
        case .noTarget: return "\(co): brak Celu"
        case .failed(let message): return "\(co): błąd — \(message)"
        }
    }

    /// Starts or stops probing to match `deviceState` and `pairing` together.
    /// Called whenever either changes.
    ///
    /// The probe has no business running during pairing — while confirming,
    /// presses are consumed by `PairingConfirmation` and never reach Meet, so
    /// there is nothing a probe result would explain; while merely browsing
    /// candidates or waiting to connect, querying the browser competes for
    /// the same script queue a user action on the still-connected saved
    /// device might need. Pairing ending (confirmed, cancelled, or failed)
    /// re-evaluates immediately, so probing resumes at once if the device is
    /// still Armed.
    private func updateProbing() {
        if deviceState == .armed, pairing == .inactive {
            startProbing()
        } else {
            stopProbing()
        }
    }

    private func startProbing() {
        guard probeTimer == nil else { return }
        refreshTarget()
        probeTimer = Timer.scheduledTimer(withTimeInterval: Self.probeInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refreshTarget() }
        }
    }

    private func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
        target = nil
        rssi = nil
        probeError = nil
        probeInFlight = false
        probePending = false
        // Invalidates any probe in flight — its result concerns state from
        // before the disconnect and has no business coming back to the
        // screen.
        probeGeneration += 1
        // Nothing left to watch while probing is stopped — not Armed, or
        // mid-pairing. Cleared here rather than only where it was set, so it
        // can't outlive the connection it was measuring.
        idleDeadline = nil
    }

    /// One probe cycle: where the Target is, what state it's in, and how
    /// strong the device's signal is. Signal strength arrives asynchronously
    /// via onRSSI.
    ///
    /// The probe must not pile up: if the browser hung, a timer firing every
    /// 3 seconds would keep stacking calls forever. But it also must not
    /// drop requests — a refresh after an Action is deliberate, and losing
    /// it would leave the pre-Action state on screen until the next cycle.
    /// Hence the pending flag: at most one probe waits in the queue, and it
    /// starts right after the current one.
    ///
    /// Package visibility (not `private`) is deliberate — `AppState` tests
    /// call this method directly, to pin down races without waiting on a
    /// timer or a real BLE disconnect.
    func refreshTarget() {
        // The probe only makes sense while the device is Armed and no
        // pairing is in progress. Without the first half of this guard, a
        // refresh delayed after an Action could start after the disconnect
        // and write a Target for a device that's no longer there. The second
        // half covers the same delayed-refresh case landing during pairing —
        // updateProbing() already stops the periodic timer, but a one-off
        // refresh scheduled by perform() reaches this guard directly.
        guard deviceState == .armed, pairing == .inactive else { return }
        guard !probeInFlight else {
            probePending = true
            return
        }
        probeInFlight = true
        probePending = false
        probeGeneration += 1
        let generation = probeGeneration
        let browsers = browserOrder()
        let controller = self.controller
        connection.readRSSI()
        scriptQueue.run(
            background: { controller.probe(browsers: browsers) },
            main: { [weak self] outcome in
                guard let self else { return }
                probeInFlight = false
                // Stale result: the probe was stopped, or a newer one
                // started, in the meantime. It has no business overwriting
                // anything.
                guard generation == probeGeneration else { return }
                switch outcome {
                case .target(let target):
                    self.target = target
                    probeError = nil
                    // A Meet Target is the strongest signal someone is
                    // actually in a call — restart the idle-sleep countdown.
                    resetIdleClock()
                case .noTarget:
                    target = nil
                    probeError = nil
                case .failed(let message):
                    // A probe failure must not masquerade as no call in
                    // progress — the menu bar has to show the cause, not
                    // "everything's fine".
                    target = nil
                    probeError = message
                }
                // Every probe cycle — found, empty, or failed — is also the
                // idle policy's own clock tick: the probe already only runs
                // while Armed and outside pairing, exactly the condition
                // under which the idle countdown is meaningful, so no
                // separate timer is needed to drive it.
                checkIdleDeadline()
                if probePending { refreshTarget() }
            }
        )
    }

    /// Evaluates whether the search deadline has passed, without waiting on
    /// the real `searchTimer`. A no-op outside `.searching` — choosing a
    /// candidate already invalidates `searchTimer` (see
    /// `choosePairingCandidate(_:)`), so a deadline superseded by a choice
    /// can't retroactively fail it.
    ///
    /// Bounds an otherwise-unbounded scan (final review, Issue 4): dismissing
    /// the menu mid-search without cancelling used to leave `TrikiConnection`
    /// scanning indefinitely, with the Meet probe suppressed the whole time.
    ///
    /// Package visibility (not `private`), same reasoning as `refreshTarget()`:
    /// tests force this deterministically instead of scheduling and waiting
    /// on a real `Timer`.
    func checkSearchDeadline() {
        guard case .searching = pairing else { return }
        searchTimer?.invalidate()
        searchTimer = nil
        // `pairing` assigned before calling into `connection`: nothing has
        // been chosen yet in `.searching`, so `TrikiConnection.cancelPairing()`
        // doesn't call back synchronously here, but keeping the order
        // consistent with the other teardown paths costs nothing and avoids
        // relying on that staying true.
        pairing = .failed(Self.searchFailureMessage)
        connection.cancelPairing()
        updateProbing()
    }

    /// Evaluates whether the connect deadline has passed, without waiting on
    /// the real `connectTimer`. A no-op outside `.connecting`.
    ///
    /// Package visibility (not `private`), same reasoning as `refreshTarget()`:
    /// tests force a timeout deterministically through the injected `now`
    /// clock instead of scheduling and waiting on a real `Timer`.
    func checkConnectDeadline() {
        guard case .connecting = pairing else { return }
        attemptTimer?.invalidate()
        attemptTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        confirmation = nil
        chosenRequired = nil
        droppedDuringAttempt = false
        // Tears down the stuck candidate and restores the previously saved
        // device's suspended connection, if there was one.
        connection.cancelPairing()
        pairing = .failed(Self.connectFailureMessage)
        updateProbing()
    }

    /// Evaluates whether the overall attempt deadline has passed, without
    /// waiting on the real `attemptTimer`. A no-op outside `.connecting`/
    /// `.confirming` — in particular, a no-op if the attempt already
    /// concluded through `checkConnectDeadline()`/`checkPressDeadline()`/a
    /// full press count/`cancelPairing()` before this fired, since all of
    /// those already invalidate `attemptTimer`.
    ///
    /// Fix round 2, Finding 1: this is what actually closes the flapping
    /// gap — `connectTimer` and `pressTimer` alone cannot, because both
    /// restart on every `.confirming` ↔ `.connecting` transition a flapping
    /// device causes, so neither's individual deadline is ever reached.
    ///
    /// Package visibility (not `private`), same reasoning as `refreshTarget()`:
    /// tests force this deterministically instead of scheduling and waiting
    /// on a real `Timer`.
    func checkAttemptDeadline() {
        switch pairing {
        case .connecting, .confirming: break
        case .inactive, .searching, .failed: return
        }
        attemptTimer?.invalidate()
        attemptTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        pressTimer?.invalidate()
        pressTimer = nil
        confirmation = nil
        chosenRequired = nil
        droppedDuringAttempt = false
        // `pairing` assigned before calling into `connection` (final review,
        // Issue 5) — see the comment on `cancelPairing()`.
        pairing = .failed(Self.flappingFailureMessage)
        connection.cancelPairing()
        updateProbing()
    }

    /// Evaluates whether the press deadline has passed, without waiting on
    /// the real `pressTimer`. A no-op outside `.confirming`.
    ///
    /// Package visibility (not `private`), same reasoning as `refreshTarget()`:
    /// tests force a timeout deterministically through the injected `now`
    /// clock instead of scheduling and waiting on a real `Timer`.
    func checkPressDeadline() {
        guard case .confirming = pairing, var pending = confirmation else { return }
        let outcome = pending.tick(at: now())
        confirmation = pending
        handlePairingOutcome(outcome)
    }

    /// Restarts the idle-sleep countdown from `now()`. Called on any
    /// evidence someone is around: the device just Armed (`onState`), the
    /// probe found a Target (`refreshTarget()`), or a button event reached
    /// `perform(_:)` (`onEvent`). A long meeting where nobody presses
    /// anything still keeps resetting this — the probe re-finds the Target
    /// every `probeInterval` for as long as the call lasts.
    private func resetIdleClock() {
        idleDeadline = now() + Self.idleTimeout
    }

    /// Evaluates whether the idle-sleep deadline has passed. Driven by
    /// `refreshTarget()`'s own cadence rather than a dedicated timer — the
    /// probe already only runs while Armed and outside pairing, exactly the
    /// window in which this deadline is meaningful, so reusing it costs
    /// nothing extra and can't drift out of sync with it.
    ///
    /// Compares against `now()` explicitly, unlike the pairing deadline
    /// checks above: those are one-shot and never reset mid-phase, so being
    /// called at all already means the deadline passed. `idleDeadline` is
    /// reset far more often than it fires (see `resetIdleClock()`), so this
    /// has to be able to tell "recently reset" from "genuinely idle" instead
    /// of treating every call as a foregone conclusion.
    ///
    /// Package visibility (not `private`), same reasoning as the other
    /// deadline checks: `AppStateTests` calls this directly through the
    /// injected clock instead of waiting on real time.
    func checkIdleDeadline() {
        guard deviceState == .armed, pairing == .inactive,
              let idleDeadline, now() >= idleDeadline else { return }
        self.idleDeadline = nil
        // Disconnects without forgetting — see `disconnectIdle()`'s doc
        // comment. `didDisconnectPeripheral`'s existing reconnect-on-advertise
        // path (the same one an ordinary loss of range already takes) brings
        // the device back the moment its button next wakes it; `updateProbing()`
        // (via the incoming `onState(.disconnected)`/`.searching`) stops the
        // probe on its own, so nothing keeps polling the browsers while
        // asleep.
        connection.disconnectIdle()
    }
}
