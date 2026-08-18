import SwiftUI
import TrikiMuteCore

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        Text(state.deviceDescription)
        if let battery = state.battery {
            Text("Bateria: \(battery)%")
        }
        if let rssi = state.rssi {
            Text("Sygnał: \(rssi) dBm")
        }
        Text(state.targetDescription)
        Text("Ostatnia akcja: \(state.lastAction)")

        Divider()

        Button("Przełącz mikrofon") { state.perform(.microphone) }
        Button("Przełącz kamerę") { state.perform(.camera) }

        Divider()

        pairingSection

        Divider()

        Button(state.loginItemDescription) { state.toggleLoginItem() }
        if let loginItemError = state.loginItemError {
            Text("Autostart: \(loginItemError)")
        }
        Button("Zakończ") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Pairing lives entirely in one place in the menu — this switches on
    /// `AppState.pairing` and renders whichever step is current. It replaces
    /// the old standalone "Zapomnij Kapsel" button: starting pairing is now
    /// also how you change device, and it leaves the previous one connected
    /// and working until a new one is actually confirmed.
    @ViewBuilder
    private var pairingSection: some View {
        switch state.pairing {
        case .inactive:
            // Same action either way; the label is the only thing that
            // changes between "first pairing" and "change device". Keyed off
            // whether a device is saved, not off `deviceState` — that can
            // read `.error` (e.g. Bluetooth off) even with a device already
            // saved, which used to show "Paruj Kapsla" in that case.
            Button(state.hasSavedDevice ? "Zmień Kapsla" : "Paruj Kapsla") {
                state.startPairing()
            }

        case .searching(let candidates):
            // The Kapsel sleeps and doesn't advertise until its button is
            // pressed — the single most important fact about this hardware
            // for anyone staring at an empty list (final review, Issue 4).
            if candidates.isEmpty {
                Text("Szukam Kapsli… naciśnij przycisk kapsla, żeby go obudzić.")
            } else {
                ForEach(candidates) { candidate in
                    Button("\(candidate.name) (\(candidate.rssi) dBm)") {
                        state.choosePairingCandidate(candidate.id)
                    }
                }
                Text("Innego nie widać? Naciśnij jego przycisk, żeby go obudzić.")
            }
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .connecting(let candidate):
            // Distinct from the press countdown below — Finding 1 (fix
            // round 1) flagged that showing the same text for "still
            // connecting" and "counting presses" left the user unable to
            // tell which one had actually failed.
            Text("Łączę się z „\(candidate.name)”…")
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .confirming(let candidate, let remaining, let resetAfterDrop):
            Text(confirmingText(name: candidate.name, remaining: remaining, resetAfterDrop: resetAfterDrop))
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .failed(let message):
            Text(message)
            Button("Wróć do listy") { state.startPairing() }
            Button("Anuluj parowanie") { state.cancelPairing() }
        }
    }

    /// `resetAfterDrop` (fix round 2, Finding 2) — a dropped connection
    /// confirms nothing, so a reconnect genuinely restarts the press count
    /// from zero. That's correct, but silent is not: without this, a user
    /// who had already pressed twice of three would keep pressing once more
    /// after a drop and be confused when it timed out anyway.
    private func confirmingText(name: String, remaining: Int, resetAfterDrop: Bool) -> String {
        guard resetAfterDrop else {
            return "Potwierdź „\(name)”: naciśnij przycisk jeszcze \(remaining)×"
        }
        return "Połączenie się zerwało — licz od nowa. Potwierdź „\(name)”: naciśnij przycisk jeszcze \(remaining)×"
    }
}
