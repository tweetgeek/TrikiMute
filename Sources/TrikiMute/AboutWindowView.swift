import SwiftUI

/// Identifier shared between the `Window` scene declared in `TrikiMuteApp`
/// and the place that opens it (`MenuBarView.aboutEntry`) — same pattern as
/// `PairingWindow.id`, see that type's doc comment for why a `Window` scene
/// (not `WindowGroup`) is what makes this a singleton: reopening focuses the
/// existing window instead of stacking a second one.
enum AboutWindow {
    static let id = "informacje"
}

/// Formats the parts of the About screen that come from the app bundle
/// rather than being hardcoded — specifically the name and version, so this
/// screen can't drift from `Info.plist`'s `CFBundleShortVersionString`/
/// `CFBundleVersion`, which is the actual source of truth for what shipped.
///
/// Takes the info dictionary directly rather than a `Bundle`, so it's
/// testable with a plain literal dictionary instead of needing a real
/// bundle on disk — `Bundle.main.infoDictionary` is passed in at the one
/// call site, `AboutWindowView.body`.
enum AboutInfo {
    static func versionLine(from infoDictionary: [String: Any]?) -> String {
        let name = infoDictionary?["CFBundleName"] as? String ?? "TrikiMute"
        let shortVersion = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(shortVersion) (\(build))"
    }
}

/// Static "About" screen, reachable from the menu's bottom cluster next to
/// autostart and quit — see `MenuBarView.aboutEntry`. Follows the same
/// presentation mechanism `PairingWindowView` already established: a
/// singleton `Window` scene (declared in `TrikiMuteApp`), opened with an
/// explicit `NSApplication.shared.activate(ignoringOtherApps:)` before
/// `openWindow` so the window actually becomes key from this `LSUIElement`
/// (accessory, no Dock icon) app instead of appearing behind whatever app
/// currently has focus — see `MenuBarView.pairingEntry`'s doc comment for
/// why that call is necessary at all.
///
/// Unlike the pairing window, there is no live state to reflect and nothing
/// to size for — one screen's worth of static content, so `.contentSize`
/// windowResizability (set alongside the `Window` scene in `TrikiMuteApp`)
/// is all that's needed to make it hug exactly that content, no manual
/// width/height bounds like `PairingWindowView.contentWidth`.
struct AboutWindowView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 4) {
                Text(AboutInfo.versionLine(from: Bundle.main.infoDictionary))
                    .font(.headline)
                Text("Sterowanie mikrofonem i kamerą w rozmowie Google Meet za pomocą fizycznego kontrolera BLE Żabka Triki.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 4) {
                Text("Autor: Sebastian Dawidziak")
                Link("Kontakt: sebastian@tweetgeek.pl", destination: Self.contactURL)
            }
            .font(.callout)

            Text("Projekt niezwiązany z Żabką — powstał na własny użytek autora. Aplikacja steruje jego prywatnym urządzeniem Triki.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 300)
    }

    /// A plain `mailto:` link, not a button that shells out — `Link` renders
    /// as tappable text styled like a hyperlink (this screen's one visible
    /// affordance besides the underlying window chrome) and hands the URL to
    /// the system's default mail client the same way clicking a `mailto:`
    /// link anywhere else in macOS does.
    private static let contactURL = URL(string: "mailto:sebastian@tweetgeek.pl")!
}
