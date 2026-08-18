import AppKit

/// Kolejność odpytywania przeglądarek. Ta na wierzchu idzie pierwsza — jeśli
/// masz otwarte dwie rozmowy, wygrywa ta, na którą właśnie patrzysz.
enum BrowserOrder {
    static let wszystkie = ["Google Chrome", "Brave Browser"]

    /// Nazwy aplikacji dla AppleScript, z aktywną przeglądarką na początku.
    static func uporzadkowane() -> [String] {
        guard let aktywna = NSWorkspace.shared.frontmostApplication?.localizedName,
              wszystkie.contains(aktywna) else {
            return wszystkie
        }
        return [aktywna] + wszystkie.filter { $0 != aktywna }
    }
}
