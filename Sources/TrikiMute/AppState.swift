import Foundation
import Observation
import TrikiMuteCore

/// The state of an in-progress device pairing, driven by `AppState` and
/// switched on directly by the menu.
///
/// `searching` and `confirming` both count as "a session is live" — see
/// `startPairing()`'s guard. `failed` is not live: it's a terminal state the
/// user must acknowledge (retry via `startPairing()` again, or `cancelPairing()`)
/// rather than something that clears itself, so the message in it is
/// guaranteed to still be there when the user next opens the menu.
enum PairingPhase: Equatable {
    case inactive
    case searching([DeviceCandidate])
    case confirming(candidate: DeviceCandidate, remaining: Int)
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
    private var probeTimer: Timer?
    private var probeInFlight = false
    /// Non-nil for the duration of `.confirming`. Owns the press count and
    /// the deadline for the candidate currently being confirmed.
    private var confirmation: PairingConfirmation?
    /// Fires once, at the pairing deadline, so a candidate that never sends
    /// a button event (the ghost-candidate case: it stopped advertising and
    /// `connect()` never calls back) still resolves to `.failed` instead of
    /// leaving `.confirming` waiting forever. A button press reaching the
    /// deadline first is handled by `consume(_:at:)` directly; this timer is
    /// only needed for the all-silence case.
    private var pairingTimer: Timer?
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

    /// Probe interval. The probe only runs while the device is Armed —
    /// outside of a call there's nothing to poll.
    private static let probeInterval: TimeInterval = 3.0

    /// How long, from choosing a candidate, the user has to both let it
    /// connect and press its button the required number of times. One
    /// deadline covers both jobs — see the ghost-candidate design note on
    /// `choosePairingCandidate(_:)`. Not `private`: `AppStateTests` crosses
    /// it deliberately via the injected clock.
    static let pairingTimeout: TimeInterval = 20.0

    /// Scripts run off the main thread. `NSAppleScript` blocks for the
    /// duration of the exchange with the browser, and on first use also for
    /// the duration of the user's answer to the permission prompt — on the
    /// main thread that would freeze the menu bar. The queue is serial, so
    /// the probe and Actions don't step on each other. State is only mutated
    /// after returning to the main thread.
    ///
    /// `connection`, `controller`, and `scriptQueue` are initializer
    /// parameters solely so that tests can substitute doubles for real
    /// CoreBluetooth, AppleScript, and background threads. The defaults
    /// reproduce the existing production wiring, so `AppState()` in
    /// `TrikiMuteApp.swift` doesn't need to change.
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
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let connection = connection ?? TrikiConnection()
        self.connection = connection
        self.controller = controller
        self.scriptQueue = scriptQueue
        self.now = now
        connection.onState = { [weak self] state in
            guard let self else { return }
            deviceState = state
            updateProbing()
        }
        connection.onBattery = { [weak self] in self?.battery = $0 }
        connection.onRSSI = { [weak self] in self?.rssi = $0 }
        connection.onEvent = { [weak self] event in
            guard let self else { return }
            // Only the confirming phase intercepts presses — while merely
            // browsing candidates (.searching), a saved device that's still
            // connected keeps controlling Meet exactly as before pairing
            // started (see the "change device" note on startPairing()).
            if case .confirming = pairing, var pending = confirmation {
                let outcome = pending.consume(event, at: self.now())
                confirmation = pending
                handlePairingOutcome(outcome)
            } else {
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
    var iconName: String {
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
        // NSWorkspace is still queried on the main thread here.
        let browsers = BrowserOrder.ordered()
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
    /// scanning. This is the menu's single pairing entry point — with no
    /// saved device it's the first step; with one already saved it's how the
    /// user replaces it (the menu no longer offers a separate "forget"
    /// action, since choosing and confirming a new device is a strict
    /// superset of it). The previously saved device, if any, keeps working
    /// undisturbed until a new one is actually confirmed — see
    /// `choosePairingCandidate(_:)` and `TrikiConnection.startPairing()`.
    ///
    /// Guards against two cases: a session already `.searching` or
    /// `.confirming` is left alone rather than silently replaced (a second
    /// call would otherwise discard a chosen candidate's `PairingConfirmation`
    /// while its connection stayed live — flagged in Task 2's review). A
    /// `.failed` phase, by contrast, is not live — this is also how the menu's
    /// "back to the list" action re-enters discovery after a timeout.
    func startPairing() {
        switch pairing {
        case .searching, .confirming: return
        case .inactive, .failed: break
        }
        pairing = .searching([])
        connection.startPairing()
        updateProbing()
    }

    /// Picks a candidate from the current list, connects to it, and starts
    /// the press-count confirmation for it.
    ///
    /// **Ghost-candidate hang (Task 2 review):** `connect()` has no timeout
    /// of its own, and a capsule that stopped advertising mid-scan can still
    /// be sitting in `candidates` — chosen, its connection would otherwise
    /// hang forever with the app stuck on "searching". This does not wait
    /// for the connection to succeed before starting the clock: `pairing`
    /// moves to `.confirming` immediately, with the same deadline that
    /// bounds the press count also bounding the connect attempt. If the
    /// candidate is gone, no button events will ever arrive, `pairingTimer`
    /// fires at the deadline regardless, and `.failed` follows — the exact
    /// same path as a live candidate whose owner presses too slowly. One
    /// mechanism closes both the hang and the ordinary timeout, and there is
    /// no separate "connecting" phase to get stuck in because none is ever
    /// entered.
    ///
    /// The alternative the brief offered — evicting candidates that stop
    /// advertising — was not implemented: the brief's own note that a bound
    /// is required either way (the device can still vanish between the list
    /// being drawn and the row being clicked) makes it strictly additional
    /// complexity in `TrikiConnection`, not a substitute for the bound.
    func choosePairingCandidate(_ id: UUID) {
        guard case .searching(let candidates) = pairing,
              let candidate = candidates.first(where: { $0.id == id }) else { return }
        connection.choose(id)
        let required = PairingConfirmation.randomRequirement()
        confirmation = PairingConfirmation(required: required, timeout: Self.pairingTimeout, startedAt: now())
        pairing = .confirming(candidate: candidate, remaining: required)
        updateProbing()
        pairingTimer?.invalidate()
        pairingTimer = Timer.scheduledTimer(withTimeInterval: Self.pairingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPairingDeadline() }
        }
    }

    /// Aborts pairing at any phase and restores whatever was connected
    /// before `startPairing()` — a no-op if nothing is in progress.
    func cancelPairing() {
        guard pairing != .inactive else { return }
        pairingTimer?.invalidate()
        pairingTimer = nil
        confirmation = nil
        connection.cancelPairing()
        pairing = .inactive
        updateProbing()
    }

    /// Applies the outcome of feeding the `PairingConfirmation` a press or a
    /// deadline check. Shared by the press path (`onEvent`) and the timer
    /// path (`checkPairingDeadline()`) so both end up in exactly the same
    /// place.
    private func handlePairingOutcome(_ outcome: PairingConfirmation.Outcome) {
        switch outcome {
        case .pending(let remaining):
            if case .confirming(let candidate, _) = pairing {
                pairing = .confirming(candidate: candidate, remaining: remaining)
            }
        case .confirmed:
            pairingTimer?.invalidate()
            pairingTimer = nil
            confirmation = nil
            connection.confirmPairing()
            pairing = .inactive
            updateProbing()
        case .timedOut:
            pairingTimer?.invalidate()
            pairingTimer = nil
            confirmation = nil
            // Tears down the stuck or unconfirmed candidate and restores the
            // previously saved device's suspended connection, if there was
            // one — same restoration `cancelPairing()` relies on.
            connection.cancelPairing()
            pairing = .failed("Nie udało się potwierdzić wyboru w wyznaczonym czasie.")
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
    /// candidates, querying the browser competes for the same script queue a
    /// user action on the still-connected saved device might need. Pairing
    /// ending (confirmed, cancelled, or failed) re-evaluates immediately, so
    /// probing resumes at once if the device is still Armed.
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
        let browsers = BrowserOrder.ordered()
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
                if probePending { refreshTarget() }
            }
        )
    }

    /// Evaluates whether the pairing deadline has passed, without waiting on
    /// the real `pairingTimer`. A no-op outside `.confirming`.
    ///
    /// Package visibility (not `private`), same reasoning as `refreshTarget()`:
    /// tests force a timeout deterministically through the injected `now`
    /// clock instead of scheduling and waiting on a real `Timer`.
    func checkPairingDeadline() {
        guard case .confirming = pairing, var pending = confirmation else { return }
        let outcome = pending.tick(at: now())
        confirmation = pending
        handlePairingOutcome(outcome)
    }
}
