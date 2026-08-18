import Foundation
import Testing
import TrikiMuteCore
@testable import TrikiMute

/// Fixed stand-in for `BrowserOrder.ordered()`, passed to every `AppState`
/// built in this file. Without it, `AppState` would fall back to its
/// production default and read the real `NSWorkspace.shared.frontmostApplication`
/// — whichever browser happens to be frontmost while the suite runs would
/// then reorder this list out from under the tests, and any assertion that
/// depends on which browser answered first (e.g. `ProbeResult.browser`)
/// would fail or pass for a reason that has nothing to do with what it's
/// testing. See `docs/follow-ups.md`.
private let testBrowserOrder = ["Google Chrome", "Brave Browser"]

/// Fake `TrikiConnection`: lets tests call `onState`/`onEvent` directly,
/// without real CoreBluetooth.
@MainActor
private final class FakeDeviceConnection: DeviceConnection {
    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((DeviceState) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?
    var onCandidates: (([DeviceCandidate]) -> Void)?

    private(set) var startCalled = false
    private(set) var startPairingCallCount = 0
    private(set) var cancelPairingCalled = false
    private(set) var confirmPairingCalled = false
    private(set) var forgetCalled = false
    private(set) var disconnectIdleCalled = false
    private(set) var chosenID: UUID?

    var startPairingCalled: Bool { startPairingCallCount > 0 }
    /// Controls what `startPairing()` reports back — flip to `false` to
    /// simulate Bluetooth not being ready (Issue 1, final review).
    var startPairingResult = true
    var hasSavedDevice = false
    /// Controls what `confirmPairing()` reports back — flip to `false` to
    /// simulate the identity guard refusing (Issue 2, final review).
    var confirmPairingResult = true
    /// When true, `cancelPairing()` synchronously emits `onState(.disconnected)`
    /// before returning — mirrors what the real `TrikiConnection.cancelPairing()`
    /// does once a candidate has been chosen, so a stale-assignment-order
    /// defect in `AppState` (Issue 5, final review) would be exercised: the
    /// reentrant callback would still see the phase this call was supposed to
    /// be tearing down.
    var cancelPairingEmitsDisconnected = false

    func start() { startCalled = true }
    func readRSSI() {}
    /// Mirrors the real `TrikiConnection.forget()`: always clears the saved
    /// device and always emits `onState(.disconnected)` synchronously,
    /// unconditionally — not gated behind a flag like
    /// `cancelPairingEmitsDisconnected`, because the real method never gates
    /// it either.
    func forget() {
        forgetCalled = true
        hasSavedDevice = false
        onState?(.disconnected)
    }
    /// Mirrors the real `TrikiConnection.disconnectIdle()`: leaves
    /// `hasSavedDevice` untouched (unlike `forget()`) and emits the same
    /// `.disconnected` → `.searching` pair `didDisconnectPeripheral`'s
    /// reconnect-on-advertise path produces for an ordinary drop — the saved
    /// device survives, and the app goes back to waiting for a press to
    /// re-arm it, not to idle-with-nothing-saved.
    func disconnectIdle() {
        disconnectIdleCalled = true
        onState?(.disconnected)
        onState?(.searching)
    }
    @discardableResult
    func startPairing() -> Bool {
        startPairingCallCount += 1
        return startPairingResult
    }
    func choose(_ id: UUID) { chosenID = id }
    func cancelPairing() {
        cancelPairingCalled = true
        if cancelPairingEmitsDisconnected { onState?(.disconnected) }
    }
    @discardableResult
    func confirmPairing() -> Bool {
        confirmPairingCalled = true
        return confirmPairingResult
    }
}

private struct RunnerError: Error {}

/// Fake `ScriptRunner`: hands back programmed responses in order. "THROW"
/// throws instead of returning — lets us reproduce a browser that doesn't
/// answer. Same pattern as in `MeetControllerTests`, duplicated
/// deliberately: this test target can't see the other test target's
/// private types.
private final class FakeRunner: ScriptRunner {
    var responses: [String]
    private(set) var executed: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func run(_ source: String) throws -> String {
        executed.append(source)
        let response = responses.isEmpty ? "NONE" : responses.removeFirst()
        if response == "THROW" { throw RunnerError() }
        return response
    }
}

/// A queue driven manually by the test, instead of real threads and real
/// delays.
///
/// `background` (background work: `perform`/`probe`) runs immediately,
/// synchronously, on the calling thread — deterministically, without a real
/// thread hop. `main` (return to the main thread) and `afterDelay` (refresh
/// delayed after an Action) land in the queue and wait for an explicit call
/// to `flush()`. This lets the test inject other calls at exactly the point
/// where a thread hop would be in flight in production — i.e. reproduce a
/// race without sleeping and without assumptions about timing.
@MainActor
private final class TestQueue: ScriptQueue {
    private(set) var runCount = 0
    private var pending: [() -> Void] = []

    func run<T>(background: @escaping () -> T, main: @escaping (T) -> Void) {
        runCount += 1
        let result = background()
        pending.append { main(result) }
    }

    func afterDelay(_ delay: TimeInterval, execute: @escaping () -> Void) {
        pending.append(execute)
    }

    /// Runs every task queued so far, in the order it was submitted. Tasks
    /// added during this call (e.g. a recursive `refreshTarget` from a
    /// pending probe) land in the next wave, not this one — exactly like a
    /// real hop onto `DispatchQueue.main` scheduled while another block on
    /// that same queue is running.
    func flush() {
        let tasks = pending
        pending = []
        for task in tasks { task() }
    }
}

// MARK: - Race 1: late probe after stop

@Test @MainActor func probeReturningAfterStopWritesNothing() {
    let connection = FakeDeviceConnection()
    // If this result landed on screen, target would stop being nil — that's
    // exactly what we check below.
    let runner = FakeRunner(["10"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    #expect(queue.runCount == 1)

    // Disconnect while the probe is in flight: bumps probeGeneration and clears state.
    connection.onState?(.disconnected)

    // The late result arrives only now.
    queue.flush()

    #expect(state.target == nil)
    #expect(state.probeError == nil)
}

// MARK: - Injected browser order

/// Mutation check for `docs/follow-ups.md`'s "Zrobione" entry on this exact
/// point: `testBrowserOrder` above is identical to `BrowserOrder.all`, which
/// is also what `BrowserOrder.ordered()` falls back to whenever the
/// frontmost application isn't one of the listed browsers — so every test in
/// this file that passes `testBrowserOrder` would keep passing even if a
/// call site were reverted to call `BrowserOrder.ordered()` directly and the
/// injected `browserOrder` parameter went unused, in any environment where a
/// browser doesn't happen to be forcibly frontmost. This test uses a
/// *reversed* order instead — genuinely different from `BrowserOrder.all` —
/// and asserts on `ProbeResult.browser`, a value that can only come out
/// reversed if `refreshTarget()` is actually calling the injected closure
/// rather than reading `NSWorkspace` on its own.
///
/// Verified the honest way (manual, not automated): temporarily changed
/// `refreshTarget()`'s `let browsers = browserOrder()` to
/// `let browsers = BrowserOrder.ordered()` — this test failed (`state.target?.browser`
/// came back `"Google Chrome"`, the production default's first entry,
/// instead of `"Brave Browser"`), while every other test in this file kept
/// passing. Reverted immediately after confirming the failure.
@Test @MainActor func probeHonorsInjectedBrowserOrderNotJustProductionDefault() {
    let connection = FakeDeviceConnection()
    let reversedOrder = Array(testBrowserOrder.reversed())
    #expect(reversedOrder != BrowserOrder.all)

    // A single length-2 response is consumed by whichever browser is tried
    // first. If the reversed order is genuinely honored, that's "Brave
    // Browser" — the *second* entry in both `BrowserOrder.all` and
    // `testBrowserOrder`, first only here.
    let runner = FakeRunner(["10"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { reversedOrder })

    connection.onState?(.armed)
    queue.flush()

    #expect(state.target?.browser == "Brave Browser")
}

// MARK: - Race 2: overlapping probes

@Test @MainActor func secondProbeQueuesAsPendingNotParallel() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["10", "01"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    #expect(queue.runCount == 1)

    // A second request before the first probe returned: it should become
    // pending, not start in parallel.
    state.refreshTarget()
    #expect(queue.runCount == 1)

    // Delivering the first probe fires the pending second one automatically.
    queue.flush()
    #expect(state.target == ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false))
    #expect(queue.runCount == 2)

    queue.flush()
    #expect(state.target == ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: true))
}

// MARK: - Race 3: refresh after disconnect

@Test @MainActor func refreshRequestedAfterDisconnectDoesNotStartProbe() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["10"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    queue.flush()
    #expect(queue.runCount == 1)

    connection.onState?(.disconnected)

    // A refresh request after disconnect has nothing to poll.
    state.refreshTarget()

    #expect(queue.runCount == 1)
    #expect(state.target == nil)
}

// MARK: - Race 4: a successful Action clears a previous error

@Test @MainActor func successfulActionClearsPreviousProbeError() {
    let connection = FakeDeviceConnection()
    // Consumption order: the first probe fails on both browsers (2 entries),
    // then a successful Action (1 entry), then a successful second probe (1 entry).
    let runner = FakeRunner(["THROW", "THROW", "OK", "10"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    queue.flush()
    #expect(state.probeError != nil)

    state.perform(.microphone)
    queue.flush()  // delivers the Action's outcome, schedules the delayed refresh
    queue.flush()  // the delayed refresh starts the second probe
    queue.flush()  // delivers the second probe's outcome

    #expect(state.probeError == nil)
    #expect(state.lastAction == "Mikrofon: przełączono")
}

// MARK: - Finding 3: an Action in flight is dropped, not queued

@Test @MainActor func actionDuringAnotherIsSkippedNotQueued() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["OK"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.perform(.microphone)
    state.perform(.camera)

    // The second Action didn't run any script — it was dropped immediately.
    #expect(queue.runCount == 1)
    #expect(state.lastAction.contains("pominięto"))

    queue.flush()
    #expect(state.lastAction == "Mikrofon: przełączono")
}

// MARK: - Pairing

/// A clock the test drives by hand — `AppState` never reads `Date()` or a
/// real `ProcessInfo.processInfo.systemUptime` in tests, so a pairing
/// deadline can be crossed deterministically without sleeping.
@MainActor
private final class FakeClock {
    var now: TimeInterval = 0
}

/// Drives `state` from `.searching` through `choosePairingCandidate(_:)` and
/// arming, landing in `.confirming`. Shared setup for every test that needs
/// to be past `.connecting` — none of those tests are about connecting
/// itself, so they shouldn't have to re-derive this each time.
@MainActor
private func chooseAndArmCandidate(
    _ state: AppState,
    _ connection: FakeDeviceConnection,
    name: String = "Kapsel-A",
    rssi: Int = -40
) -> UUID {
    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: name, rssi: rssi)])
    state.choosePairingCandidate(id)
    connection.onState?(.armed)
    return id
}

@Test @MainActor func pressDuringConfirmationDoesNotReachMeet() {
    let connection = FakeDeviceConnection()
    // If perform() ran, this response would be consumed — proof by
    // contradiction that queue.runCount == 0 below means it didn't.
    let runner = FakeRunner(["OK"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)

    guard case .confirming = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    connection.onEvent?(.press)

    #expect(queue.runCount == 0)
    #expect(state.lastAction == "—")
}

@Test @MainActor func fullPressCountConfirmsAndPersists() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)

    guard case .confirming(_, let required, _) = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    for _ in 0..<required {
        connection.onEvent?(.press)
    }

    #expect(state.pairing == .inactive)
    #expect(connection.confirmPairingCalled)
    // Presses spent on confirmation must never have triggered a Meet Action —
    // lastAction stays at its initial placeholder. (queue.runCount can be
    // nonzero here: once pairing ends, updateProbing() correctly resumes the
    // probe for the now-Armed, now-confirmed device — a probe, not an Action.)
    #expect(state.lastAction == "—")
}

/// The plain press-timeout case: the candidate connects and arms fine, the
/// user simply doesn't press enough times before `pressTimeout`. Distinct
/// from `candidateThatNeverArmsFailsWithConnectSpecificMessage` below —
/// fix round 1 split what used to be one shared timeout into two, precisely
/// so these two causes are no longer indistinguishable to the user.
@Test @MainActor func pressTimeoutFailsWithoutPersisting() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    clock.now += AppState.pressTimeout + 1
    state.checkPressDeadline()

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed after the press deadline passed")
        return
    }
    #expect(message == AppState.pressFailureMessage)
    #expect(!connection.confirmPairingCalled)
}

@Test @MainActor func cancelDuringPairingLeavesSavedDeviceUntouched() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -40)])
    state.choosePairingCandidate(id)

    guard case .connecting = state.pairing else {
        Issue.record("expected .connecting right after choosing, before arming")
        return
    }

    state.cancelPairing()

    #expect(state.pairing == .inactive)
    #expect(connection.cancelPairingCalled)
    // The only method that would overwrite the saved identifier was never called.
    #expect(!connection.confirmPairingCalled)
}

@Test @MainActor func pressOutsidePairingStillTogglesMic() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["OK"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onEvent?(.press)

    #expect(queue.runCount == 1)
    queue.flush()
    #expect(state.lastAction == "Mikrofon: przełączono")
}

/// The ghost-candidate hang found in Task 2's review: a capsule that stops
/// advertising mid-scan stays in the list, and `connect()` on it never times
/// out on its own. Pins that choosing it now fails cleanly — bounded by
/// `connectTimeout` — instead of leaving pairing stuck on "searching"
/// forever, and that the failure message is the connect-specific one, not
/// the press-timeout message (fix round 1, Finding 1).
@Test @MainActor func candidateThatNeverArmsFailsWithConnectSpecificMessage() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -60)])
    state.choosePairingCandidate(id)
    // Deliberately no connection.onState?(.armed) — the candidate vanished
    // and CoreBluetooth's connect() never calls back at all.

    clock.now += AppState.connectTimeout + 1
    state.checkConnectDeadline()

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed, not stuck in .connecting or .searching")
        return
    }
    #expect(message == AppState.connectFailureMessage)
    #expect(message != AppState.pressFailureMessage)
    #expect(connection.cancelPairingCalled)

    // No hang: pairing can be started again right away.
    state.startPairing()
    #expect(state.pairing == .searching([]))
    #expect(connection.startPairingCalled)
}

/// Finding 1 (fix round 1): a candidate that takes nearly the whole connect
/// budget to arm must still get the *full* press window afterward, not
/// whatever was left over from a single shared deadline.
@Test @MainActor func candidateThatArmsLateStillGetsFullPressWindow() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -40)])
    state.choosePairingCandidate(id)
    guard case .connecting = state.pairing else {
        Issue.record("expected .connecting immediately after choosing")
        return
    }

    // Connecting eats nearly the entire connect budget...
    clock.now += AppState.connectTimeout - 1
    connection.onState?(.armed)

    guard case .confirming(_, let required, _) = state.pairing else {
        Issue.record("expected .confirming once armed")
        return
    }

    // ...but the press window starts fresh from the moment of arming, not
    // from the moment the candidate was chosen — so nearly the full press
    // deadline is still available, well past what the old shared budget
    // would have allowed.
    clock.now += AppState.pressTimeout - 1
    for _ in 0..<required {
        connection.onEvent?(.press)
    }

    #expect(state.pairing == .inactive)
    #expect(connection.confirmPairingCalled)
}

/// Finding 1 (fix round 1), second part: a drop mid-confirmation must not
/// leave a stale press countdown on screen against a device that's gone.
/// Pairing falls back to `.connecting` — distinctly rendered by the menu —
/// rather than staying in `.confirming` with no way to tell the user what
/// actually happened.
@Test @MainActor func dropMidConfirmationReturnsToConnectingInsteadOfStaleCountdown() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    // The device drops before confirmation completes.
    connection.onState?(.disconnected)

    guard case .connecting = state.pairing else {
        Issue.record("expected .connecting again after a mid-confirmation drop")
        return
    }
}

/// Fix round 2, Finding 2 — the review flagged the previous version of this
/// test (`dropMidConfirmationPreservesTheOriginalRequiredCount`) for never
/// pressing before dropping, so it couldn't distinguish "progress reset" from
/// "progress preserved": both would show `remaining == required` either way.
/// This version presses first, so `remaining` has actually moved off
/// `required` before the drop, then asserts it snaps back — proving the
/// reset is real — while also confirming the *ceiling* number (`required`)
/// itself never changes, and that `resetAfterDrop` — the flag the menu
/// reads to tell the user their count restarted — flips from `false` to
/// `true` exactly when it should.
@Test @MainActor func dropMidConfirmationResetsProgressButKeepsTheOriginalRequiredCount() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming(_, let required, let resetBeforeDrop) = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }
    #expect(resetBeforeDrop == false)
    #expect(required >= 2)  // PairingConfirmation.requiredRange is 2...5 — always room for one press.

    // Make real progress before the drop.
    connection.onEvent?(.press)
    guard case .confirming(_, let remainingAfterOnePress, _) = state.pairing else {
        Issue.record("expected still .confirming after one press (below the minimum required)")
        return
    }
    #expect(remainingAfterOnePress == required - 1)

    // The device drops with progress on the board, then reconnects.
    connection.onState?(.disconnected)
    connection.onState?(.armed)

    guard case .confirming(_, let remainingAfterReconnect, let resetAfterDrop) = state.pairing else {
        Issue.record("expected .confirming again after reconnecting")
        return
    }
    // Progress genuinely restarted — not left at remainingAfterOnePress.
    #expect(remainingAfterReconnect == required)
    // ...and the menu is told so, instead of silently resetting.
    #expect(resetAfterDrop == true)
}

/// Fix round 2, Finding 1 — the round 1 split traded the original unbounded
/// wait for a new one: `.confirming` falling back to `.connecting` on every
/// drop restarts `connectTimer` fresh each time, so a device flapping faster
/// than either per-phase deadline never lets `connectTimer` or `pressTimer`
/// actually expire. This proves `attemptTimer`'s independent, non-restarting
/// bound is what actually resolves it — not a side effect of the per-phase
/// timers, which this test shows are insufficient on their own by checking
/// pairing is still genuinely live after the flapping, before invoking
/// `checkAttemptDeadline()`. Before `attemptTimer`/`checkAttemptDeadline()`
/// existed (fix round 1's code), this test could not even compile — the
/// method didn't exist — which is as unambiguous a "fails against the prior
/// implementation" as a compiled-language test can demonstrate.
@Test @MainActor func repeatedDropsEventuallyFailInsteadOfFlappingForever() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -70)])
    state.choosePairingCandidate(id)

    // The device flaps at the edge of range: arms, drops, arms, drops... —
    // each drop hands connectTimer a fresh 10s, so neither per-phase timer
    // alone would ever reach its deadline if this kept up indefinitely.
    for _ in 0..<20 {
        connection.onState?(.armed)
        connection.onState?(.disconnected)
    }

    // Proof the per-phase timers alone never resolved it: still genuinely
    // mid-pairing after all that flapping.
    switch state.pairing {
    case .connecting, .confirming: break
    default:
        Issue.record("expected still mid-pairing after flapping — the per-phase timers should not have resolved this on their own")
        return
    }

    // The overall attempt bound is independent of the per-phase restarts.
    state.checkAttemptDeadline()

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed once the overall attempt budget passed, not stuck flapping")
        return
    }
    #expect(message == AppState.flappingFailureMessage)
    #expect(connection.cancelPairingCalled)

    // No hang: pairing can be started again right away.
    state.startPairing()
    #expect(state.pairing == .searching([]))
}

// MARK: - Final review fixes

/// Issue 1: `startPairing()` used to set `.searching([])` unconditionally,
/// even when `TrikiConnection.startPairing()` silently refused (e.g.
/// Bluetooth off) — the menu kept showing "Szukam Kapsli…" forever with no
/// scan actually running. `deviceState` already carries the specific cause
/// via `onState(.error(...))`, which fires synchronously on every
/// CoreBluetooth state change — this pins that `startPairing()` reads it
/// instead of announcing a search.
@Test @MainActor func startPairingFailureNamesCauseInsteadOfAnnouncingSearch() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.error("Bluetooth jest wyłączony"))
    connection.startPairingResult = false

    state.startPairing()

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed naming the cause instead of announcing a search that isn't running")
        return
    }
    #expect(message == "Bluetooth jest wyłączony")
    #expect(connection.startPairingCallCount == 1)
}

/// Issue 1, second half: the menu's pairing button label must track whether
/// a device is actually saved, not `deviceState` — which can read `.error`
/// (Bluetooth off) even with a device saved, and used to show "Paruj Kapsla"
/// (first-time wording) in that case instead of "Zmień Kapsla".
@Test @MainActor func hasSavedDeviceReflectsConnectionRegardlessOfDeviceState() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.hasSavedDevice = true
    connection.onState?(.error("Bluetooth jest wyłączony"))

    #expect(state.hasSavedDevice)
}

@Test @MainActor func startPairingRefusedWhileSessionAlreadyLive() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.startPairing()
    #expect(connection.startPairingCallCount == 1)
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -40)])

    // A session is already live — the second call must be refused without
    // touching TrikiConnection again or discarding the candidate list already
    // collected.
    state.startPairing()

    #expect(connection.startPairingCallCount == 1)
    #expect(state.pairing == .searching([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -40)]))
}

/// Issue 2: `confirmPairing()` must be able to refuse — persisting the wrong
/// identity would defeat the whole point of pairing. A refusal has to reach
/// the user instead of `AppState` announcing confirmation unconditionally.
@Test @MainActor func confirmationRefusalSurfacesAsFailedInsteadOfSilentSuccess() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming(_, let required, _) = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }
    connection.confirmPairingResult = false

    for _ in 0..<required {
        connection.onEvent?(.press)
    }

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed instead of announcing a device that was never actually saved")
        return
    }
    #expect(!message.isEmpty)
    #expect(connection.confirmPairingCalled)
}

/// Issue 4: dismissing the menu without cancelling used to leave
/// `TrikiConnection` scanning indefinitely, with the Meet probe suppressed
/// the whole time. `.searching` is now bounded the same way `.connecting`
/// and `.confirming` already were.
@Test @MainActor func searchTimeoutFailsAndStopsScanning() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    state.startPairing()
    #expect(state.pairing == .searching([]))

    clock.now += AppState.searchTimeout + 1
    state.checkSearchDeadline()

    guard case .failed(let message) = state.pairing else {
        Issue.record("expected .failed once the search deadline passed")
        return
    }
    #expect(message == AppState.searchFailureMessage)
    #expect(connection.cancelPairingCalled)
}

/// Issue 4, second half: the mic-state icon must not claim live information
/// during pairing — the probe is suppressed for the whole session (see
/// `updateProbing()`), so `target` can be stale or `nil` even while a saved
/// device stays connected and Armed in the background.
@Test @MainActor func iconIsDistinctWhilePairingEvenIfASavedDeviceStaysArmed() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    #expect(state.iconName == "mic.fill")

    state.startPairing()
    #expect(state.iconName != "mic.fill")
    #expect(state.iconName != "mic.slash.fill")
}

/// Coverage gap the final review flagged: `.connecting` already drops button
/// events (there is no confirmation to count them against yet, and the
/// previously connected device was already disconnected by `choose(_:)`),
/// but nothing pinned it.
@Test @MainActor func pressDuringConnectingDoesNotReachMeet() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["OK"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-A", rssi: -40)])
    state.choosePairingCandidate(id)

    guard case .connecting = state.pairing else {
        Issue.record("expected .connecting right after choosing, before arming")
        return
    }

    connection.onEvent?(.press)

    #expect(queue.runCount == 0)
    #expect(state.lastAction == "—")
}

/// Issue 5: the old assignment order in `cancelPairing()` invalidated timers
/// and only then called into `connection` — but `TrikiConnection.cancelPairing()`
/// emits `onState(.disconnected)` synchronously once a candidate is chosen,
/// so the reentrant callback still saw `.confirming`, took the
/// drop-and-reconnect branch, and scheduled a fresh `connectTimer` *after*
/// the invalidation that was supposed to be the end of it. `pairing` itself
/// ends up `.inactive` either way — every teardown path's final assignment
/// clobbers it regardless of ordering — so this checks `hasNoLivePairingTimers`
/// too, which is the only place the leak is actually visible.
@Test @MainActor func cancelDuringConfirmingLeavesNoLiveTimerBehind() {
    let connection = FakeDeviceConnection()
    connection.cancelPairingEmitsDisconnected = true
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    state.cancelPairing()

    #expect(state.pairing == .inactive)
    #expect(state.hasNoLivePairingTimers)
}

/// Reachable from the menu's `.failed` case ("Anuluj parowanie"). Also pins
/// that a fresh attempt afterward doesn't inherit `droppedDuringAttempt` from
/// the failed one — `resetAfterDrop` must start `false` for a brand-new
/// candidate that has never dropped.
@Test @MainActor func cancelFromFailedReturnsToInactiveAndClearsDropFlagForNextAttempt() {
    let connection = FakeDeviceConnection()
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    // Force a drop so droppedDuringAttempt is genuinely true going into the failure.
    connection.onState?(.disconnected)
    guard case .connecting = state.pairing else {
        Issue.record("expected .connecting after the mid-confirmation drop")
        return
    }
    clock.now += AppState.connectTimeout + 1
    state.checkConnectDeadline()
    guard case .failed = state.pairing else {
        Issue.record("expected .failed after the connect deadline passed")
        return
    }

    state.cancelPairing()
    #expect(state.pairing == .inactive)

    // A fresh attempt must not inherit the previous attempt's drop flag.
    state.startPairing()
    let id = UUID()
    connection.onCandidates?([DeviceCandidate(id: id, name: "Kapsel-B", rssi: -50)])
    state.choosePairingCandidate(id)
    connection.onState?(.armed)

    guard case .confirming(_, _, let resetAfterDrop) = state.pairing else {
        Issue.record("expected .confirming once the new candidate arms")
        return
    }
    #expect(resetAfterDrop == false)
}

// MARK: - forgetDevice()

/// The plain case: nothing else in progress, just a saved device being
/// cleared. Pins the menu-visibility contract too — `hasSavedDevice` must
/// flip to `false` so the "Zapomnij Kapsel"/"Zmień Kapsla" wording in
/// `MenuBarView` reacts correctly, and `pairing` must land on `.inactive` so
/// the next thing the menu shows is the plain "Paruj Kapsla" button — the
/// only sensible next step once there's nothing saved.
@Test @MainActor func forgetDeviceClearsSavedDeviceAndLeavesAppIdle() {
    let connection = FakeDeviceConnection()
    connection.hasSavedDevice = true
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, browserOrder: { testBrowserOrder })

    state.forgetDevice()

    #expect(connection.forgetCalled)
    #expect(!state.hasSavedDevice)
    #expect(state.pairing == .inactive)
    #expect(state.deviceState == .disconnected)
}

/// Forgetting mid-pairing must win over whatever the session was doing —
/// the destructive, deliberate action tears down the live attempt rather
/// than being blocked by it or leaving it half-alive underneath. Reuses the
/// same evidence `cancelDuringConfirmingLeavesNoLiveTimerBehind` relies on:
/// `TrikiConnection.forget()` always emits `onState(.disconnected)`
/// synchronously (see `FakeDeviceConnection.forget()`), so if `pairing`
/// weren't assigned `.inactive` before calling into `connection` (the same
/// Issue 5 ordering `cancelPairing()` depends on), the reentrant callback
/// would misread the still-`.confirming` phase as an ordinary
/// mid-confirmation drop and leak a fresh `connectTimer` underneath this
/// teardown.
@Test @MainActor func forgetDeviceDuringLivePairingTearsDownSessionCoherently() {
    let connection = FakeDeviceConnection()
    connection.hasSavedDevice = true
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    _ = chooseAndArmCandidate(state, connection)
    guard case .confirming = state.pairing else {
        Issue.record("expected .confirming once the candidate is armed")
        return
    }

    state.forgetDevice()

    #expect(state.pairing == .inactive)
    #expect(state.hasNoLivePairingTimers)
    #expect(connection.forgetCalled)
    #expect(!connection.confirmPairingCalled)
    #expect(!state.hasSavedDevice)
}

// MARK: - Idle-sleep disconnect

/// The plain case: the device Arms, no Meet Target ever shows up, and
/// `idleTimeout` passes. The saved identifier must survive (this is not
/// `forgetDevice()`), and the app must land back on `.searching` — waiting
/// for the next press to re-arm it — rather than on `.disconnected` with
/// nothing saved.
@Test @MainActor func idleTimeoutDisconnectsAfterTargetAbsentAndReturnsToWaiting() {
    let connection = FakeDeviceConnection()
    connection.hasSavedDevice = true
    // Every probe call returns .noTarget (see MeetController.probe: an
    // empty FakeRunner always answers "NONE", which is neither length 2
    // nor an error) — nothing here ever resets the idle clock.
    let controller = MeetController(runner: FakeRunner([]))
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    #expect(state.deviceState == .armed)

    clock.now += AppState.idleTimeout + 1
    state.checkIdleDeadline()

    #expect(connection.disconnectIdleCalled)
    // Not forgotten: the saved identifier survives.
    #expect(!connection.forgetCalled)
    #expect(state.hasSavedDevice)
    // Back to waiting for a press, not idle-with-nothing-saved.
    #expect(state.deviceState == .searching)
}

/// A long meeting where nobody presses anything must not disconnect the
/// device: as long as the probe keeps finding a Target, the deadline keeps
/// moving out. This proves the reset is real by advancing past the
/// *original* deadline and showing the disconnect still doesn't fire,
/// because a later Target sighting pushed a new one further out.
@Test @MainActor func idleTimeoutDoesNotFireWhileTargetKeepsAppearing() {
    let connection = FakeDeviceConnection()
    // "10" decodes as a Target found (mic muted, camera on) — see
    // MeetController.probe and the existing race tests above for the same
    // response shape.
    let runner = FakeRunner(["10", "10"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)
    queue.flush()  // delivers the immediate probe startProbing() triggers
    #expect(state.target != nil)  // idleDeadline now (0 + idleTimeout) = idleTimeout

    // Well before the original deadline, a fresh Target sighting pushes it
    // out again.
    clock.now += AppState.idleTimeout - 50
    state.refreshTarget()
    queue.flush()
    #expect(state.target != nil)  // idleDeadline now (idleTimeout - 50) + idleTimeout

    // Enough time has passed since arming that the *original* deadline
    // would have fired by now, but not enough since the Target was last
    // seen.
    clock.now += 100
    state.checkIdleDeadline()

    #expect(!connection.disconnectIdleCalled)
    #expect(state.deviceState == .armed)
}

/// Same proof as above, but for button events instead of Target sightings —
/// someone actively using the device (even with no Target, e.g. testing the
/// toggle outside a call) must not have it disconnected out from under them.
@Test @MainActor func idleTimeoutDoesNotFireWhilePressesKeepArriving() {
    let connection = FakeDeviceConnection()
    // First response answers the probe that arming triggers immediately
    // (found on the first browser, so it consumes exactly one runner call);
    // the second is reserved for the press-triggered perform() call below.
    let runner = FakeRunner(["00", "OK"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let clock = FakeClock()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue, now: { clock.now }, browserOrder: { testBrowserOrder })

    connection.onState?(.armed)  // idleDeadline now (0 + idleTimeout)
    queue.flush()  // delivers the immediate probe

    // Well before the original deadline, a press pushes it out again.
    clock.now += AppState.idleTimeout - 50
    connection.onEvent?(.press)  // idleDeadline now (idleTimeout - 50) + idleTimeout
    queue.flush()
    #expect(state.lastAction == "Mikrofon: przełączono")

    // Enough time has passed since arming that the *original* deadline
    // would have fired by now, but not enough since the last press.
    clock.now += 100
    state.checkIdleDeadline()

    #expect(!connection.disconnectIdleCalled)
    #expect(state.deviceState == .armed)
}
