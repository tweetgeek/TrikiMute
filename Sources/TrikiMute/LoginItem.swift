import ServiceManagement

/// Uruchamianie przy logowaniu. `SMAppService.mainApp` działa tylko dla
/// podpisanego pakietu .app — uruchomiona wprost binarka zgłosi błąd.
enum LoginItem {
    static var wlaczone: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func przelacz() {
        do {
            if wlaczone {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Autostart: \(error)")
        }
    }
}
