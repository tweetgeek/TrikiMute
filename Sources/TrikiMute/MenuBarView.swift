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

        Button(state.loginItemDescription) { state.toggleLoginItem() }
        if let loginItemError = state.loginItemError {
            Text("Autostart: \(loginItemError)")
        }
        Button("Zapomnij Kapsel") { state.forgetDevice() }
        Button("Zakończ") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
