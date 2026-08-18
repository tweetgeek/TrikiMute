import SwiftUI

@main
struct TrikiMuteApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(systemName: state.nazwaIkony)
        }
        .menuBarExtraStyle(.menu)
    }
}
