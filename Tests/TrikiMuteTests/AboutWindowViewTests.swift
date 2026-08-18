import Testing
@testable import TrikiMute

/// Pins `AboutInfo.versionLine(from:)` — the one piece of the About screen
/// with any actual logic (reading name/version out of a bundle's info
/// dictionary instead of hardcoding them). Everything else on that screen
/// is static layout, verified visually instead — see `/tmp/about-report.md`
/// for how.
@Suite("AboutInfo")
struct AboutInfoTests {
    @Test func versionLineCombinesNameShortVersionAndBuild() {
        let info: [String: Any] = [
            "CFBundleName": "TrikiMute",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        #expect(AboutInfo.versionLine(from: info) == "TrikiMute 1.0 (1)")
    }

    @Test func versionLineFallsBackWhenInfoDictionaryIsNil() {
        #expect(AboutInfo.versionLine(from: nil) == "TrikiMute ? (?)")
    }

    @Test func versionLineFallsBackWhenKeysAreMissing() {
        #expect(AboutInfo.versionLine(from: [:]) == "TrikiMute ? (?)")
    }
}
