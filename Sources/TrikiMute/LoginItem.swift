import ServiceManagement

/// Uruchamianie przy logowaniu. `SMAppService.mainApp` działa tylko dla
/// podpisanego pakietu .app — uruchomiona wprost binarka zgłosi błąd.
enum LoginItem {
    /// Stan rejestracji w formie, jaką da się pokazać w menu.
    enum Stan: Equatable {
        case wylaczony
        case wlaczony
        /// Zarejestrowany, ale czeka na zatwierdzenie w Ustawieniach
        /// systemowych. Bez tego stanu wygląda identycznie jak wyłączony,
        /// więc kliknięcie prowadziłoby do ponownej rejestracji zamiast
        /// skierować użytkownika tam, gdzie sprawa czeka na decyzję.
        case wymagaZatwierdzenia
    }

    static var stan: Stan {
        switch SMAppService.mainApp.status {
        case .enabled: return .wlaczony
        case .requiresApproval: return .wymagaZatwierdzenia
        default: return .wylaczony
        }
    }

    static var wlaczone: Bool { stan == .wlaczony }

    /// Zwraca opis błędu, jeśli operacja się nie powiodła.
    ///
    /// Rejestracja bywa blokowana przez politykę zarządzania urządzeniem albo
    /// ograniczenia `SMAppService`. Zgłaszanie tego przez `print` byłoby
    /// bezużyteczne: aplikacja uruchamiana przez LaunchServices nie ma gdzie
    /// wypisywać, a użytkownik w tym momencie patrzy akurat na menu.
    static func przelacz() -> String? {
        do {
            if wlaczone {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
