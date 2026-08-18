import Foundation
import Testing
import TrikiMuteCore
@testable import TrikiMute

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
    private(set) var forgetCalled = false
    private(set) var startPairingCalled = false
    private(set) var cancelPairingCalled = false
    private(set) var confirmPairingCalled = false
    private(set) var chosenID: UUID?

    func start() { startCalled = true }
    func readRSSI() {}
    func forget() { forgetCalled = true }
    func startPairing() { startPairingCalled = true }
    func choose(_ id: UUID) { chosenID = id }
    func cancelPairing() { cancelPairingCalled = true }
    func confirmPairing() { confirmPairingCalled = true }
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
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue)

    connection.onState?(.armed)
    #expect(queue.runCount == 1)

    // Disconnect while the probe is in flight: bumps probeGeneration and clears state.
    connection.onState?(.disconnected)

    // The late result arrives only now.
    queue.flush()

    #expect(state.target == nil)
    #expect(state.probeError == nil)
}

// MARK: - Race 2: overlapping probes

@Test @MainActor func secondProbeQueuesAsPendingNotParallel() {
    let connection = FakeDeviceConnection()
    let runner = FakeRunner(["10", "01"])
    let controller = MeetController(runner: runner)
    let queue = TestQueue()
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue)

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
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue)

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
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue)

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
    let state = AppState(connection: connection, controller: controller, scriptQueue: queue)

    state.perform(.microphone)
    state.perform(.camera)

    // The second Action didn't run any script — it was dropped immediately.
    #expect(queue.runCount == 1)
    #expect(state.lastAction.contains("pominięto"))

    queue.flush()
    #expect(state.lastAction == "Mikrofon: przełączono")
}
