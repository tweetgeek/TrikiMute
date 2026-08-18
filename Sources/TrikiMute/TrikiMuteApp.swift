import SwiftUI

@main
struct TrikiMuteApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(systemName: state.iconName)
        }
        .menuBarExtraStyle(.menu)

        // The pairing flow's own window (`PairingWindowView`), opened on
        // demand from the menu's pairing row — never shown at launch. A
        // `Window` scene (not `WindowGroup`) is a singleton: `openWindow(id:)`
        // on an already-open instance brings it forward instead of creating
        // a second one, which is exactly the "reopen focuses, doesn't stack"
        // behavior pairing needs. `.contentSize` lets the window hug the
        // VStack's natural size instead of starting at some arbitrary
        // resizable default — this is a small, single-purpose utility
        // window, not a document window.
        Window("Parowanie Kapsla", id: PairingWindow.id) {
            PairingWindowView(state: state)
        }
        .windowResizability(.contentSize)

        // The About screen, opened on demand from the menu's bottom
        // cluster — see `MenuBarView.aboutEntry`. Same singleton `Window`
        // reasoning as pairing above: reopening focuses the one instance
        // instead of stacking a second. `.contentSize` fits the window to
        // `AboutWindowView`'s fixed-width static content — it never needs
        // to resize or scroll.
        Window("O aplikacji", id: AboutWindow.id) {
            AboutWindowView()
        }
        .windowResizability(.contentSize)
    }
}
