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

// MARK: - Failure.validated

// `Failure.validated(_:browser:)` guards the other mandatory-to-test failure
// mode named in the design doc: JavaScript execution disabled from Apple
// Events. Extracted so it can be exercised without a real browser process.

@Test func validatedAcceptsAValidString() throws {
    let text = try ScriptingBridgeBrowsers.Failure.validated("10", browser: "Google Chrome")
    #expect(text == "10")
}

@Test func validatedRejectsNil() {
    #expect(throws: ScriptingBridgeBrowsers.Failure.self) {
        try ScriptingBridgeBrowsers.Failure.validated(nil, browser: "Google Chrome")
    }
    do {
        _ = try ScriptingBridgeBrowsers.Failure.validated(nil, browser: "Google Chrome")
        Issue.record("Oczekiwano rzuconego błędu")
    } catch let failure as ScriptingBridgeBrowsers.Failure {
        #expect(failure.message == "Google Chrome nie zwrócił wyniku JavaScriptu — sprawdź "
            + "View → Developer → Allow JavaScript from Apple Events")
    } catch {
        Issue.record("Zły typ błędu: \(error)")
    }
}

@Test func validatedRejectsANonStringValue() {
    do {
        _ = try ScriptingBridgeBrowsers.Failure.validated(42, browser: "Brave Browser")
        Issue.record("Oczekiwano rzuconego błędu")
    } catch let failure as ScriptingBridgeBrowsers.Failure {
        #expect(failure.message == "Brave Browser nie zwrócił wyniku JavaScriptu — sprawdź "
            + "View → Developer → Allow JavaScript from Apple Events")
    } catch {
        Issue.record("Zły typ błędu: \(error)")
    }
}

// MARK: - Failure.sweep

// `Failure.sweep` is the decision between "genuinely nothing here" and "an
// Apple Event got swallowed" — the one thing standing between a real failure
// and a false `.noTarget`. Tested here with `Element == String` standing in
// for a tab's URL, since the decision doesn't care what the payload is.

@Test func sweepCollectsEverythingWhenEverythingAnswered() throws {
    let result = try ScriptingBridgeBrowsers.Failure.sweep(
        [["https://a.example", "https://b.example"], ["https://c.example"]],
        browser: "Google Chrome"
    )
    #expect(result == ["https://a.example", "https://b.example", "https://c.example"])
}

@Test func sweepThrowsWhenNothingAnswered() {
    do {
        _ = try ScriptingBridgeBrowsers.Failure.sweep([nil, nil] as [[String?]?], browser: "Google Chrome")
        Issue.record("Oczekiwano rzuconego błędu")
    } catch let failure as ScriptingBridgeBrowsers.Failure {
        #expect(failure.message == "Google Chrome nie odpowiedział na pytanie o karty")
    } catch {
        Issue.record("Zły typ błędu: \(error)")
    }
}

@Test func sweepCollectsTheWindowThatAnsweredWhenAnotherDidNot() throws {
    let result = try ScriptingBridgeBrowsers.Failure.sweep(
        [["https://a.example"], nil],
        browser: "Google Chrome"
    )
    #expect(result == ["https://a.example"])
}

@Test func sweepThrowsWhenAnAnsweringEmptyWindowIsPairedWithAWindowThatDidNotAnswer() {
    // Pinned to today's behaviour: a window that genuinely has zero tabs
    // contributes nothing to `result`, so an unanswering sibling window still
    // leaves `result` empty — and an empty result alongside any `unanswered`
    // window throws, rather than being read as "no call here".
    do {
        _ = try ScriptingBridgeBrowsers.Failure.sweep([[] as [String?], nil], browser: "Google Chrome")
        Issue.record("Oczekiwano rzuconego błędu")
    } catch let failure as ScriptingBridgeBrowsers.Failure {
        #expect(failure.message == "Google Chrome nie odpowiedział na pytanie o karty")
    } catch {
        Issue.record("Zły typ błędu: \(error)")
    }
}
