import SwiftUI
import TrikiMuteCore

@main
struct TrikiMuteApp: App {
    @State private var most = MostTestowy()

    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Text(most.opis)
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Tymczasowe spięcie Kapsla z Meet. Zastąpione przez AppState w Task 9.
@MainActor
@Observable
final class MostTestowy {
    private(set) var opis = "Start…"
    private let polaczenie = TrikiConnection()
    private let controller = MeetController(runner: AppleScriptRunner())

    init() {
        polaczenie.onState = { [weak self] stan in
            self?.opis = "Kapsel: \(stan)"
            print("Stan: \(stan)")
        }
        polaczenie.onBattery = { print("Bateria: \($0)%") }
        polaczenie.onEvent = { [weak self] zdarzenie in
            guard let self else { return }
            let akcja: MeetAction = zdarzenie == .press ? .microphone : .camera
            let wynik = controller.perform(akcja, browsers: BrowserOrder.uporzadkowane())
            print("Zdarzenie \(zdarzenie) → \(akcja) → \(wynik)")
        }
        polaczenie.start()
    }
}
