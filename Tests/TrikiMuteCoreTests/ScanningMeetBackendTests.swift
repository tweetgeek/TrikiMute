import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

private struct AccessError: Error {}

/// Fake tab: answers with a programmed response, or throws.
/// `nil` response means "this tab throws when executed".
private final class FakeTab: BrowserTab {
    let url: String
    private let response: String?
    private(set) var executed: [String] = []

    init(url: String, response: String?) {
        self.url = url
        self.response = response
    }

    func execute(_ javascript: String) throws -> String {
        executed.append(javascript)
        guard let response else { throw AccessError() }
        return response
    }
}

/// Fake access: hands out programmed tabs per pid, or throws for pids listed
/// as broken — the case where one Instance is unreachable while another
/// answers normally.
private final class FakeAccess: BrowserAccess {
    private let tabsByPid: [pid_t: [FakeTab]]
    private let brokenPids: Set<pid_t>
    private(set) var queriedPids: [pid_t] = []

    init(tabsByPid: [pid_t: [FakeTab]], brokenPids: Set<pid_t> = []) {
        self.tabsByPid = tabsByPid
        self.brokenPids = brokenPids
    }

    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab] {
        queriedPids.append(instance.pid)
        if brokenPids.contains(instance.pid) { throw AccessError() }
        return tabsByPid[instance.pid] ?? []
    }
}

@Test func probeFindsTargetInTheSecondInstance() {
    // The regression for the whole piece of work: the first Instance is the
    // tool-launched one with no call in it, the Target lives in the second.
    let access = FakeAccess(tabsByPid: [
        38259: [FakeTab(url: "http://localhost:8011/panel", response: nil)],
        1450: [FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "10")],
    ])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ])
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func probeSkipsTabsThatArentMeetWithoutExecutingAnything() {
    let idle = FakeTab(url: "https://example.com", response: "10")
    let access = FakeAccess(tabsByPid: [1450: [idle]])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
    #expect(idle.executed.isEmpty)
}

@Test func probeSkipsMeetTabsWithoutAFullSetOfButtons() {
    // Today's behaviour, kept 1:1: a Meet tab answering NONE is passed over
    // and the search carries on to the next tab.
    let waiting = FakeTab(url: "https://meet.google.com/waiting", response: "NONE")
    let live = FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "01")
    let access = FakeAccess(tabsByPid: [1450: [waiting, live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: true)))
}

@Test func probeReportsFailureWhenAnInstanceIsUnreachableAndNoTargetIsFound() {
    // A failure must never masquerade as "no call in progress" — the menu bar
    // would then claim everything is fine while, say, Automation access had
    // been revoked.
    let access = FakeAccess(tabsByPid: [:], brokenPids: [1450])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    if case .failed = outcome {} else { Issue.record("Oczekiwano .failed") }
}

@Test func probeReturnsTargetEvenIfAnEarlierInstanceFailed() {
    // One broken Instance must not hide a working Target in another.
    let access = FakeAccess(
        tabsByPid: [1445: [FakeTab(url: "https://meet.google.com/abc", response: "11")]],
        brokenPids: [1450]
    )
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ])
    #expect(outcome == .target(ProbeResult(browser: "Brave Browser", micMuted: true, cameraOff: true)))
}

@Test func probeStopsAtTheFirstInstanceWithATarget() {
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/first", response: "00")],
        1445: [FakeTab(url: "https://meet.google.com/second", response: "11")],
    ])
    let backend = ScanningMeetBackend(access: access)
    _ = backend.probe(instances: [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ])
    #expect(access.queriedPids == [1450])
}

@Test func probeRejectsAnswersThatArentTwoCharacters() {
    // Anything the injected JavaScript can't have produced is an anomaly, not
    // an answer — decoding it as "mic live, camera live" would be a failure
    // wearing the mask of a valid reading.
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/abc", response: "nonsense")],
    ])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
}

@Test func performClicksInTheInstanceThatHasTheTarget() {
    let idle = FakeTab(url: "https://localhost/panel", response: nil)
    let live = FakeTab(url: "https://meet.google.com/abc", response: "OK")
    let access = FakeAccess(tabsByPid: [38259: [idle], 1450: [live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.perform(.microphone, instances: [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ])
    #expect(outcome == .performed)
    #expect(live.executed.count == 1)
}

@Test func performReportsNoTargetWhenNothingAnswersOK() {
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/waiting", response: "NONE")],
    ])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.perform(.camera, instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
}

@Test func performReportsFailureWhenAnInstanceIsUnreachable() {
    let access = FakeAccess(tabsByPid: [:], brokenPids: [1450])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.perform(.microphone, instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    if case .failed = outcome {} else { Issue.record("Oczekiwano .failed") }
}

@Test func probeSkipsTabsThatThrowAndFindsTargetInNextTab() {
    // A throw from the first tab must not abort the tab loop. If the first tab
    // mid-navigation throws, the second tab that holds the actual call must
    // still be checked and found.
    let throwing = FakeTab(url: "https://meet.google.com/mid-navigation", response: nil)
    let live = FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "11")
    let access = FakeAccess(tabsByPid: [1450: [throwing, live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: true)))
}

@Test func performSkipsTabsThatThrowAndClicksInNextTab() {
    // A throw from the first tab must not abort the tab loop. If the first tab
    // mid-navigation throws, the second tab that holds the actual call must
    // still be checked and clicked.
    let throwing = FakeTab(url: "https://meet.google.com/mid-navigation", response: nil)
    let live = FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "OK")
    let access = FakeAccess(tabsByPid: [1450: [throwing, live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.perform(.microphone, instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(outcome == .performed)
}
