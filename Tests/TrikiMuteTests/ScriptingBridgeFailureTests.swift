import Testing
@testable import TrikiMute

// `ScriptingBridgeBrowsers.Failure.appleEvent(code:browser:)` is the one
// genuinely testable piece of logic in ScriptingBridgeBrowsers.swift: a pure
// mapping from an Apple Event error code to the Polish message shown to the
// user, extracted out of `ErrorTrap` (which talks to real Apple Events and
// can't be unit-tested) so this mapping can be checked without a browser.

@Test func appleEventFailureNamesRevokedAutomationPermission() {
    let failure = ScriptingBridgeBrowsers.Failure.appleEvent(code: -1743, browser: "Google Chrome")
    #expect(failure.message == "Brak zgody na sterowanie Google Chrome — włącz ją w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja")
}

@Test func appleEventFailureNamesTheProcessGoingAway() {
    let goneWhileAsking = ScriptingBridgeBrowsers.Failure.appleEvent(code: -600, browser: "Brave Browser")
    let goneWhileConnecting = ScriptingBridgeBrowsers.Failure.appleEvent(code: -609, browser: "Brave Browser")
    #expect(goneWhileAsking.message == "Brave Browser przestał działać w trakcie sprawdzania")
    #expect(goneWhileConnecting.message == "Brave Browser przestał działać w trakcie sprawdzania")
}

@Test func appleEventFailureFallsBackToTheRawCodeForAnythingElse() {
    let failure = ScriptingBridgeBrowsers.Failure.appleEvent(code: -1728, browser: "Google Chrome")
    #expect(failure.message == "Google Chrome: błąd Apple Events -1728")
}
