import SwiftUI
import TrikiMuteCore

/// Identifier shared between the `Window` scene declared in `TrikiMuteApp`
/// and the places that open or dismiss it — `MenuBarView.pairingEntry` and
/// `PairingWindowView` itself. A `String` constant, not a magic literal
/// repeated at each call site.
enum PairingWindow {
    static let id = "parowanie"
}

/// Standalone window for the pairing flow, replacing its old home inside the
/// menu bar menu. A native `NSMenu` closes on every click — that made the
/// one piece of feedback that actually matters here, the live press
/// countdown, disappear behind a menu the user had to keep reopening to
/// watch. This window stays on screen and updates as `AppState.pairing`
/// changes, same as any other SwiftUI view bound to `@Observable` state.
///
/// Deliberately a thin re-presentation of `AppState.pairing`, not a new
/// source of truth: every case here mirrors what the menu's old inline
/// pairing section rendered, phase for phase, wording for wording. Pairing
/// logic itself — timers, timeouts, the confirmation count — is untouched;
/// see `AppState`.
struct PairingWindowView: View {
    let state: AppState

    /// Used to close the window itself once a session concludes on its own
    /// — see the `onChange` below for exactly when.
    @Environment(\.dismissWindow) private var dismissWindow

    private static let pairingIcon = "dot.radiowaves.left.and.right"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(20)
        .frame(minWidth: 340, alignment: .leading)
        .onChange(of: state.pairing) { oldPhase, newPhase in
            // The window closes itself only when a *live* session concludes
            // on its own — confirmed, or cancelled from any phase (both land
            // on `.inactive`). `.failed` deliberately does not close it: the
            // failure message is the one piece of information this window
            // exists to keep visible, and closing out from under it would
            // reintroduce exactly the problem the window was built to fix.
            // Guarded on `oldPhase != .inactive` so the window's very first
            // render — already non-`.inactive` by the time it appears, since
            // `MenuBarView.pairingEntry` starts pairing before opening the
            // window — never matches this and closes itself immediately.
            if newPhase == .inactive, oldPhase != .inactive {
                dismissWindow(id: PairingWindow.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.pairing {
        case .inactive:
            // Reachable only for the brief instant between a session
            // concluding and the `dismissWindow` call above actually taking
            // effect — the window is never opened while `pairing` already
            // reads `.inactive` (see `MenuBarView.pairingEntry`).
            Text("Parowanie zakończone.")

        case .searching(let candidates):
            // The Kapsel sleeps and doesn't advertise until its button is
            // pressed — the single most important fact for anyone staring at
            // an empty list.
            if candidates.isEmpty {
                Label("Szukam Kapsli… naciśnij przycisk kapsla, żeby go obudzić.", systemImage: Self.pairingIcon)
            } else {
                Text("Wybierz Kapsel:")
                    .font(.headline)
                ForEach(candidates) { candidate in
                    Button {
                        state.choosePairingCandidate(candidate.id)
                    } label: {
                        Label("\(candidate.name) (\(candidate.rssi) dBm)", systemImage: Self.pairingIcon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
                Label("Innego nie widać? Naciśnij jego przycisk, żeby go obudzić.", systemImage: Self.pairingIcon)
                    .foregroundStyle(.secondary)
            }
            cancelButton

        case .connecting(let candidate):
            // Distinct from the press countdown below — showing the same
            // text for "still connecting" and "counting presses" would leave
            // the user unable to tell which one had actually failed.
            Label("Łączę się z „\(candidate.name)”…", systemImage: Self.pairingIcon)
            cancelButton

        case .confirming(let candidate, let remaining, let resetAfterDrop):
            // A dedicated "press the button" icon rather than the generic
            // pairing one — this is the one phase where the user's next move
            // is a physical action on the Kapsel itself, not a choice in
            // this window.
            Label(
                confirmingText(name: candidate.name, remaining: remaining, resetAfterDrop: resetAfterDrop),
                systemImage: "hand.tap.fill"
            )
            .font(.headline)
            cancelButton

        case .failed(let message):
            // Same triangle the tray and the menu's pairing entry use for
            // "something is broken" — a failed pairing attempt is itself a
            // fault the user has to acknowledge, not a step still in
            // progress.
            Label(message, systemImage: "exclamationmark.triangle.fill")
            Button {
                state.startPairing()
            } label: {
                Label("Wróć do listy", systemImage: "arrow.uturn.backward")
            }
            cancelButton
        }
    }

    /// Outline `xmark.circle`, not a filled variant — cancelling pairing is
    /// reversible and cheap, same posture the menu used for it.
    private var cancelButton: some View {
        Button {
            state.cancelPairing()
        } label: {
            Label("Anuluj parowanie", systemImage: "xmark.circle")
        }
    }

    /// `resetAfterDrop` — a dropped connection confirms nothing, so a
    /// reconnect genuinely restarts the press count from zero. That's
    /// correct, but silent is not: without this, a user who had already
    /// pressed twice of three would keep pressing once more after a drop and
    /// be confused when it timed out anyway.
    private func confirmingText(name: String, remaining: Int, resetAfterDrop: Bool) -> String {
        guard resetAfterDrop else {
            return "Potwierdź „\(name)”: naciśnij przycisk jeszcze \(remaining)×"
        }
        return "Połączenie się zerwało — licz od nowa. Potwierdź „\(name)”: naciśnij przycisk jeszcze \(remaining)×"
    }
}
