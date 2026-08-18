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
            // changes between "first pairing" and "change device".
            Button(state.deviceState == .disconnected ? "Paruj Kapsla" : "Zmień Kapsla") {
                state.startPairing()
            }

        case .searching(let candidates):
            if candidates.isEmpty {
                Text("Szukam Kapsli…")
            } else {
                ForEach(candidates) { candidate in
                    Button("\(candidate.name) (\(candidate.rssi) dBm)") {
                        state.choosePairingCandidate(candidate.id)
                    }
                }
            }
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .connecting(let candidate):
            // Distinct from the press countdown below — Finding 1 (fix
            // round 1) flagged that showing the same text for "still
            // connecting" and "counting presses" left the user unable to
            // tell which one had actually failed.
            Text("Łączę się z „\(candidate.name)”…")
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .confirming(let candidate, let remaining):
            Text("Potwierdź „\(candidate.name)”: naciśnij przycisk jeszcze \(remaining)×")
            Button("Anuluj parowanie") { state.cancelPairing() }

        case .failed(let message):
            Text(message)
            Button("Wróć do listy") { state.startPairing() }
            Button("Anuluj parowanie") { state.cancelPairing() }
        }
    }
}
