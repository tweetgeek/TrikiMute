import SwiftUI
import TrikiMuteCore

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        Text(state.opisKapsla)
        if let bateria = state.bateria {
            Text("Bateria: \(bateria)%")
        }
        if let rssi = state.rssi {
            Text("Sygnał: \(rssi) dBm")
        }
        Text(state.opisCelu)
        Text("Ostatnia akcja: \(state.ostatniaAkcja)")

        Divider()

        Button("Przełącz mikrofon") { state.wykonaj(.microphone) }
        Button("Przełącz kamerę") { state.wykonaj(.camera) }

        Divider()

        Button(LoginItem.wlaczone ? "✓ Uruchamiaj przy logowaniu" : "Uruchamiaj przy logowaniu") {
            LoginItem.przelacz()
        }
        Button("Zapomnij Kapsel") { state.zapomnijKapsel() }
        Button("Zakończ") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
