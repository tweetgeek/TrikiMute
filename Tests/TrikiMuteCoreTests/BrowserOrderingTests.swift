// Tests/TrikiMuteCoreTests/BrowserOrderingTests.swift
import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

@Test func activeInstanceWinsOverBrowserOrderAndPid() {
    // Brave is later in the list and has a higher pid, but it's the one the
    // user is looking at — "the browser you're looking at wins" is the rule
    // this whole ordering exists to preserve.
    let instances = [
        BrowserInstance(pid: 100, browser: chrome, isActive: false),
        BrowserInstance(pid: 900, browser: brave, isActive: true),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.pid) == [900, 100])
}

@Test func chromeBeatsBraveWhenNeitherIsActive() {
    let instances = [
        BrowserInstance(pid: 100, browser: brave, isActive: false),
        BrowserInstance(pid: 200, browser: chrome, isActive: false),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.browser.name) == ["Google Chrome", "Brave Browser"])
}

@Test func lowerPidWinsBetweenInstancesOfTheSameBrowser() {
    // The tool-launched instance starts later, so it gets the higher pid —
    // this key is what puts the user's own browser first.
    let instances = [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.pid) == [1450, 38259])
}

@Test func orderingIsTotalSoTheSameInputAlwaysGivesTheSameTarget() {
    // NSWorkspace makes no promise about the order it returns processes in,
    // so the same set arriving shuffled must still order identically.
    let a = BrowserInstance(pid: 1450, browser: chrome, isActive: false)
    let b = BrowserInstance(pid: 38259, browser: chrome, isActive: false)
    let c = BrowserInstance(pid: 1445, browser: brave, isActive: false)
    let one = BrowserOrdering.ordered([a, b, c], supported: [chrome, brave])
    let two = BrowserOrdering.ordered([c, b, a], supported: [chrome, brave])
    #expect(one == two)
    #expect(one.map(\.pid) == [1450, 38259, 1445])
}

@Test func supportedListNamesBothBrowsers() {
    // One list, two uses: bundle identifiers find the processes, names are
    // what AppleScript and the menu call them.
    #expect(BrowserOrdering.supported.map(\.bundleID)
        == ["com.google.Chrome", "com.brave.Browser"])
    #expect(BrowserOrdering.supported.map(\.name)
        == ["Google Chrome", "Brave Browser"])
}
