import Foundation
import Observation
import TrikiMuteCore

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

    private let connection: any DeviceConnection
    private let controller: MeetController
    private let scriptQueue: any ScriptQueue
    private var probeTimer: Timer?
    private var probeInFlight = false
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
        )
    ) {
        let connection = connection ?? TrikiConnection()
        self.connection = connection
        self.controller = controller
        self.scriptQueue = scriptQueue
        connection.onState = { [weak self] state in
            guard let self else { return }
            deviceState = state
            state == .armed ? startProbing() : stopProbing()
        }
        connection.onBattery = { [weak self] in self?.battery = $0 }
        connection.onRSSI = { [weak self] in self?.rssi = $0 }
        connection.onEvent = { [weak self] event in
            self?.perform(event == .press ? .microphone : .camera)
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

    func forgetDevice() {
        connection.forget()
    }

    func toggleLoginItem() {
        loginItemError = LoginItem.toggle()
    }

    private func describe(_ action: MeetAction, _ outcome: ActionOutcome) -> String {
        let co = action == .microphone ? "Mikrofon" : "Kamera"
        switch outcome {
        case .performed: return "\(co): przełączono"
        case .noTarget: return "\(co): brak Celu"
        case .failed(let message): return "\(co): błąd — \(message)"
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
        // The probe only makes sense while the device is Armed. Without this
        // guard, a refresh delayed after an Action could start after the
        // disconnect and write a Target for a device that's no longer there.
        guard deviceState == .armed else { return }
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
}
