import SwiftUI
import TrikiMuteCore

struct MenuBarView: View {
    let state: AppState

    /// Opens (or focuses) `PairingWindowView` — see `pairingEntry` below.
    @Environment(\.openWindow) private var openWindow

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

        pairingEntry
        deviceLifecycleSection

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

    /// The menu's single pairing row — everything pairing used to render
    /// inline (the candidate list, the connecting/confirming states, the
    /// failure message) now lives continuously in `PairingWindowView`
    /// instead, specifically because a native `NSMenu` closes on every
    /// click: the press countdown, the one piece of feedback that makes
    /// confirmation usable, was disappearing behind a menu the user had to
    /// keep reopening to watch. This row just opens (or focuses) that
    /// window; `AppState.pairingMenuTitle`/`pairingMenuIcon` say what it
    /// looks like in each phase.
    ///
    /// Starting pairing here, before opening the window, rather than leaving
    /// that to the window's own first appearance: `AppState.startPairing()`
    /// is a guarded no-op while a session is already live (`.searching`,
    /// `.connecting`, `.confirming`) or on the terminal `.failed` phase — so
    /// this same action correctly begins a *new* session from `.inactive`
    /// and merely reveals an *existing* one otherwise, without the window
    /// needing to know which case it is.
    ///
    /// `NSApp.activate(ignoringOtherApps:)` before `openWindow` — this app
    /// is `LSUIElement` (accessory: no Dock icon), and an accessory app
    /// opening a window does not reliably become the frontmost, key
    /// application on its own. Without the explicit activation the window
    /// can appear behind whatever app currently has focus instead of
    /// receiving keyboard/mouse input, which would silently defeat the
    /// point of moving pairing into a window at all. Called on every click,
    /// not just the first, so reopening the window while another app is
    /// frontmost still brings it forward and focuses it — `openWindow` on an
    /// already-open, single-instance `Window` scene brings that same window
    /// forward rather than stacking a second one, but forward within our own
    /// app is not the same as actually focused on screen.
    private var pairingEntry: some View {
        Button {
            if state.pairing == .inactive {
                state.startPairing()
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: PairingWindow.id)
        } label: {
            Label(state.pairingMenuTitle, systemImage: state.pairingMenuIcon)
        }
    }

    /// "Uśpij Kapsel", "Anuluj usypianie", and "Zapomnij Kapsel" — unchanged
    /// from before the pairing window existed, both in wording and in when
    /// they show. All are device-lifecycle actions, not call actions like
    /// toggling the microphone, so they belong here rather than up with
    /// "Przełącz mikrofon"/"Przełącz kamerę". Order follows how often each
    /// is actually used: sleeping/its cancel (occasional), then forgetting
    /// last (destructive and rare). "Uśpij Kapsel" and its cancel never show
    /// at the same time — `deviceState` is never both `.armed` and
    /// `.fallingAsleep` — so putting the cancel in the same slot right after
    /// "Uśpij Kapsel" reuses the exact spot the user's pointer is already at
    /// after a misclick, without adding permanent clutter for everyone else.
    /// Sleeping and forgetting answer different questions — sleeping
    /// *disconnects* the device without touching what's saved, forgetting
    /// *removes* it with nothing to replace it — so separate buttons instead
    /// of collapsing the two together.
    ///
    /// All three stay gated on `state.pairing == .inactive`, exactly as they
    /// were when they lived inside the inline section's own `.inactive`
    /// case — deliberately not relaxed now that pairing has its own window.
    /// A previously saved device can stay Armed in the background while a
    /// *different* Kapsel is mid-pairing (see `AppState.startPairing()`'s
    /// "change device" note), and none of `sleepDevice()`/
    /// `cancelFallingAsleep()`/`forgetDevice()` needs a live session to be
    /// reachable — `AppState` itself already refuses `sleepDevice()`/
    /// `cancelFallingAsleep()` outside `.inactive`. Keeping the same
    /// visibility guard here means these rows read and behave identically
    /// to before the move, matching the requirement that everything outside
    /// pairing keeps working exactly as it did.
    @ViewBuilder
    private var deviceLifecycleSection: some View {
        if state.pairing == .inactive {
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
            // parowanie" pairs with the pairing entry above — the wording
            // names exactly what it undoes, not a new action — and shares
            // that button's outline `xmark.circle`: reversible and cheap,
            // same as cancelling pairing.
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
        }
    }
}
