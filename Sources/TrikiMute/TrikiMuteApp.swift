import SwiftUI
import TrikiMuteCore

@main
struct TrikiMuteApp: App {
    private let controller = MeetController(runner: AppleScriptRunner())

    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Button("Sonda — wypisz stan Celu") {
                let wynik = controller.probe(browsers: BrowserOrder.uporzadkowane())
                print("Sonda: \(String(describing: wynik))")
            }
            Button("Przełącz mikrofon") {
                print("Mikrofon: \(controller.perform(.microphone, browsers: BrowserOrder.uporzadkowane()))")
            }
            Button("Przełącz kamerę") {
                print("Kamera: \(controller.perform(.camera, browsers: BrowserOrder.uporzadkowane()))")
            }
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
