import SwiftUI

@main
struct TrikiMuteApp: App {
    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Text("TrikiMute")
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
