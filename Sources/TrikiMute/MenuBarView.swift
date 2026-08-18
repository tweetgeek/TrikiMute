import SwiftUI
import TrikiMuteCore

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        Label(state.deviceDescription, systemImage: state.deviceIcon)
        if let battery = state.battery {
            Label("Bateria: \(battery)%", systemImage: AppState.batteryIcon(for: battery))
        }
        if let rssi = state.rssi {
            Label("Sygnał: \(rssi) dBm", systemImage: "antenna.radiowaves.left.and.right")
        }
        Label(state.targetDescription, systemImage: state.targetIcon)
        Label("Ostatnia akcja: \(state.lastAction)", systemImage: "clock.arrow.circlepath")

        Divider()

        Button {
            state.perform(.microphone)
        } label: {
            Label("Przełącz mikrofon", systemImage: "mic")
        }
        Button {
            state.perform(.camera)
        } label: {
            Label("Przełącz kamerę", systemImage: "video")
        }

        Divider()

        pairingSection

        Divider()

        Button {
            state.toggleLoginItem()
        } label: {
            Label(state.loginItemDescription, systemImage: "power")
        }
        if let loginItemError = state.loginItemError {
            Label("Autostart: \(loginItemError)", systemImage: "exclamationmark.circle")
        }
        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Zakończ", systemImage: "xmark.circle.fill")
        }
        .keyboardShortcut("q")
    }

    /// Shared by every "still mid-pairing" row below — `dot.radiowaves.left.and.right`
    /// is exactly what `AppState.iconName` shows in the tray for the same
    /// condition (`pairing != .inactive`), so a row about choosing a device
    /// never disagrees with the icon sitting right above the menu.
    private static let pairingIcon = "dot.radiowaves.left.and.right"

    /// Pairing lives entirely in one place in the menu — this switches on
    /// `AppState.pairing` and renders whichever step is current. "Uśpij
    /// Kapsel", its cancel counterpart, and "Zapomnij Kapsel" all sit next
    /// to the pairing button, in the same `.inactive` case — all are
    /// device-lifecycle actions, not call actions like toggling the
    /// microphone, so they belong here rather than up with "Przełącz
    /// mikrofon"/"Przełącz kamerę". Order follows how often each is actually
    /// used: pairing first (common — first setup, or swapping to a
    /// different capsule), then sleeping/its cancel (occasional), then
    /// forgetting last (destructive and rare). "Uśpij Kapsel" and its cancel
    /// never show at the same time — `deviceState` is never both `.armed`
    /// and `.fallingAsleep` — so putting the cancel in the same slot right
    /// after "Uśpij Kapsel" reuses the exact spot the user's pointer is
    /// already at after a misclick, without adding permanent clutter for
    /// everyone else. Sleeping and forgetting answer different questions —
    /// pairing *replaces* the saved device, sleeping *disconnects* it
    /// without touching what's saved, forgetting *removes* it with nothing
    /// to replace it — so separate buttons instead of collapsing any two
    /// together.
    @ViewBuilder
    private var pairingSection: some View {
        switch state.pairing {
        case .inactive:
            // Same action either way; the label is the only thing that
            // changes between "first pairing" and "change device". Keyed off
            // whether a device is saved, not off `deviceState` — that can
            // read `.error` (e.g. Bluetooth off) even with a device already
            // saved, which used to show "Paruj Kapsla" in that case.
            Button {
                state.startPairing()
            } label: {
                Label(state.hasSavedDevice ? "Zmień Kapsla" : "Paruj Kapsla", systemImage: "plus.circle")
            }
            // Only meaningful — and only shown — when the Kapsel is
            // actually transmitting: `.disconnected`/`.searching` already
            // means it isn't, so there's nothing to put to sleep. Same
            // `moon.zzz.fill` symbol `AppState.deviceIcon` shows for the
            // disconnected/searching state this button produces — pressing
            // it turns the device into exactly that icon.
            if state.deviceState == .armed {
                Button {
                    state.sleepDevice()
                } label: {
                    Label("Uśpij Kapsel", systemImage: "moon.zzz.fill")
                }
            }
            // The rescue for "Uśpij Kapsel" clicked by accident (or for the
            // automatic idle disconnect landing here on its own — both
            // triggers reach the identical `.fallingAsleep` state, so one
            // button cancels either). Without this there was no way out
            // except waiting out the sleep wait — roughly three minutes for
            // the device to actually go quiet, or worse if a reflexive press
            // on the physical button kept it advertising instead. "Anuluj
            // usypianie" pairs with "Uśpij Kapsel" the same way "Anuluj
            // parowanie" pairs with "Paruj Kapsla" below — the wording names
            // exactly what it undoes, not a new action — and shares that
            // button's outline `xmark.circle`: reversible and cheap, same as
            // cancelling pairing.
            if state.deviceState == .fallingAsleep {
                Button {
                    state.cancelFallingAsleep()
                } label: {
                    Label("Anuluj usypianie", systemImage: "xmark.circle")
                }
            }
            // Only meaningful — and only shown — when there's actually
            // something saved to clear. No confirmation dialog: the action
            // is fully reversible (pair again) and already sits behind a
            // deliberate menu-bar navigation, the same lack of ceremony this
            // menu already gives "Anuluj parowanie" for a comparably
            // consequential action.
            if state.hasSavedDevice {
                Button {
                    state.forgetDevice()
                } label: {
                    Label("Zapomnij Kapsel", systemImage: "trash")
                }
            }

        case .searching(let candidates):
            // The Kapsel sleeps and doesn't advertise until its button is
            // pressed — the single most important fact about this hardware
            // for anyone staring at an empty list (final review, Issue 4).
            if candidates.isEmpty {
                Label("Szukam Kapsli… naciśnij przycisk kapsla, żeby go obudzić.", systemImage: Self.pairingIcon)
            } else {
                ForEach(candidates) { candidate in
                    Button {
                        state.choosePairingCandidate(candidate.id)
                    } label: {
                        Label("\(candidate.name) (\(candidate.rssi) dBm)", systemImage: Self.pairingIcon)
                    }
                }
                Label("Innego nie widać? Naciśnij jego przycisk, żeby go obudzić.", systemImage: Self.pairingIcon)
            }
            cancelPairingButton

        case .connecting(let candidate):
            // Distinct from the press countdown below — Finding 1 (fix
            // round 1) flagged that showing the same text for "still
            // connecting" and "counting presses" left the user unable to
            // tell which one had actually failed.
            Label("Łączę się z „\(candidate.name)”…", systemImage: Self.pairingIcon)
            cancelPairingButton

        case .confirming(let candidate, let remaining, let resetAfterDrop):
            // A dedicated "press the button" icon rather than the generic
            // pairing one — this is the one phase where the user's next
            // move is a physical action on the Kapsel itself, not a choice
            // in the menu.
            Label(
                confirmingText(name: candidate.name, remaining: remaining, resetAfterDrop: resetAfterDrop),
                systemImage: "hand.tap.fill"
            )
            cancelPairingButton

        case .failed(let message):
            // Same triangle the tray uses for "something is broken" — a
            // failed pairing attempt is itself a fault the user has to
            // acknowledge, not a step still in progress.
            Label(message, systemImage: "exclamationmark.triangle.fill")
            Button {
                state.startPairing()
            } label: {
                Label("Wróć do listy", systemImage: "arrow.uturn.backward")
            }
            cancelPairingButton
        }
    }

    /// Outline `xmark.circle`, not the filled variant `Zakończ` uses — the
    /// same outline/filled distinction the tray icon uses for "ready" versus
    /// "live" carries over here: cancelling pairing is reversible and cheap,
    /// quitting the app is not.
    private var cancelPairingButton: some View {
        Button {
            state.cancelPairing()
        } label: {
            Label("Anuluj parowanie", systemImage: "xmark.circle")
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
