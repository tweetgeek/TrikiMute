import Foundation
import Testing
import TrikiMuteCore
@testable import TrikiMute

// The tuple type has to be spelled with its labels — an array of unlabelled
// tuples is a different type in Swift and won't convert on its own.
private typealias RunningApp = (bundleID: String?, pid: pid_t, isActive: Bool)

@Test func recognizesSupportedBrowsersAmongRunningApplications() {
    // The mapping under test: bundle identifier in, SupportedBrowser out,
    // everything else ignored. No NSWorkspace involved.
    let running: [RunningApp] = [
        (bundleID: "com.apple.finder", pid: 500, isActive: false),
        (bundleID: "com.google.Chrome", pid: 1450, isActive: true),
        (bundleID: nil, pid: 700, isActive: false),
        (bundleID: "com.brave.Browser", pid: 1445, isActive: false),
        (bundleID: "com.google.Chrome", pid: 38259, isActive: false),
    ]
    let instances = RunningBrowsers.instances(from: running)
    // Active Chrome (1450) first; among the two remaining inactive instances,
    // browser rank breaks the tie (Chrome before Brave) ahead of pid — the
    // same contract `orderingIsTotalSoTheSameInputAlwaysGivesTheSameTarget`
    // in BrowserOrderingTests pins down for this exact trio of pids.
    #expect(instances.map(\.pid) == [1450, 38259, 1445])
    #expect(instances.first?.browser.name == "Google Chrome")
    #expect(instances.first?.isActive == true)
}

@Test func ordersRecognizedInstancesByTheSharedRule() {
    // Active first, then Chrome before Brave, then ascending pid — the same
    // ordering BrowserOrderingTests pins down, applied here end to end.
    let running: [RunningApp] = [
        (bundleID: "com.google.Chrome", pid: 38259, isActive: false),
        (bundleID: "com.brave.Browser", pid: 1445, isActive: true),
        (bundleID: "com.google.Chrome", pid: 1450, isActive: false),
    ]
    #expect(RunningBrowsers.instances(from: running).map(\.pid) == [1445, 1450, 38259])
}

@Test func ignoresApplicationsThatArentSupportedBrowsers() {
    let running: [RunningApp] = [(bundleID: "com.apple.Safari", pid: 800, isActive: true)]
    #expect(RunningBrowsers.instances(from: running).isEmpty)
}
