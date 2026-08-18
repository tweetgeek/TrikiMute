import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

private let twoInstances = [
    BrowserInstance(pid: 1450, browser: chrome, isActive: true),
    BrowserInstance(pid: 1445, browser: brave, isActive: false),
]

private struct RunnerError: Error {}

/// Fake executor: hands back programmed responses in order and remembers the
/// scripts it ran. The value "THROW" means that call should throw.
private final class FakeRunner: ScriptRunner {
    var responses: [String]
    private(set) var executed: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func run(_ source: String) throws -> String {
        executed.append(source)
        let response = responses.isEmpty ? "NONE" : responses.removeFirst()
        if response == "THROW" { throw RunnerError() }
        return response
    }
}

/// Backend that answers with whatever it was told to, and counts its calls.
private final class StubBackend: MeetBackend {
    private let probeOutcome: ProbeOutcome
    private let actionOutcome: ActionOutcome
    private(set) var probeCalls = 0
    private(set) var performCalls = 0

    init(probe: ProbeOutcome, action: ActionOutcome = .noTarget) {
        probeOutcome = probe
        actionOutcome = action
    }

    func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        probeCalls += 1
        return probeOutcome
    }

    func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        performCalls += 1
        return actionOutcome
    }
}

// MARK: - AppleScriptMeetBackend

@Test func appleScriptBackendAsksEachBrowserNameOnceForTwoInstancesOfIt() {
    // AppleScript addresses browsers by name, so two Instances of Chrome are
    // one question to it, not two. Asking twice would be pure waste — the
    // answer cannot differ.
    let runner = FakeRunner(["NONE", "NONE"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ]
    #expect(backend.probe(instances: instances) == .noTarget)
    #expect(runner.executed.count == 2)
}

@Test func appleScriptBackendDecodesMicAndCameraState() {
    let runner = FakeRunner(["10"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let result = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(result == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func appleScriptBackendReportsErrorWhenRunnerThrows() {
    let runner = FakeRunner(["THROW"])
    let backend = AppleScriptMeetBackend(runner: runner)
    if case .failed = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) {
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func appleScriptBackendPerformsActionAndReportsSuccess() {
    let runner = FakeRunner(["OK"])
    let backend = AppleScriptMeetBackend(runner: runner)
    #expect(backend.perform(.microphone, instances: twoInstances) == .performed)
}

@Test func appleScriptBackendProbeStopsAtFirstBrowserWithTarget() {
    // Early exit: the second browser must never be asked once the first
    // already answered — that would be a needless Apple Event.
    let runner = FakeRunner(["01", "11"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    let result = backend.probe(instances: instances)
    #expect(result == .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    #expect(runner.executed.count == 1)
}

@Test func appleScriptBackendProbeFindsTargetDespiteFirstBrowserError() {
    let runner = FakeRunner(["THROW", "10"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    let result = backend.probe(instances: instances)
    #expect(result == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func appleScriptBackendProbeReportsErrorWhenOneBrowserThrowsAndOtherHasNoTarget() {
    // The case where an error could be silently overwritten by a later
    // no-target answer: a real failure must win, not read as "no call".
    let runner = FakeRunner(["THROW", "NONE"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    if case .failed = backend.probe(instances: instances) {
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

@Test func appleScriptBackendActionReportsNoTarget() {
    let runner = FakeRunner(["NONE"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]
    #expect(backend.perform(.microphone, instances: instances) == .noTarget)
}

@Test func appleScriptBackendActionReportsRunnerError() {
    let runner = FakeRunner(["THROW"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]
    if case .failed = backend.perform(.camera, instances: instances) {
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func appleScriptBackendActionSucceedsWhenFirstBrowserThrowsAndSecondWorks() {
    let runner = FakeRunner(["THROW", "OK"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    #expect(backend.perform(.microphone, instances: instances) == .performed)
}

@Test func appleScriptBackendActionReportsErrorWhenOneBrowserThrowsAndOtherHasNoTarget() {
    let runner = FakeRunner(["THROW", "NONE"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    if case .failed = backend.perform(.microphone, instances: instances) {
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

// MARK: - MeetController as a facade

@Test func controllerUsesFallbackOnlyWhenPrimaryFails() {
    let primary = StubBackend(probe: .failed("brak zgody"))
    let fallback = StubBackend(probe: .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
    let controller = MeetController(primary: primary, fallback: fallback)
    let outcome = controller.probe(instances: twoInstances)
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
    #expect(fallback.probeCalls == 1)
}

@Test func controllerNeverUsesFallbackWhenPrimarySaysNoTarget() {
    // The rule that makes the fallback sane: the primary has already searched
    // every Instance, so the fallback — which searches a subset of them — has
    // no way to find a Target it missed. Calling it would be one Apple Event
    // per browser, every 3 seconds, in the app's most common state.
    let primary = StubBackend(probe: .noTarget)
    let fallback = StubBackend(probe: .target(ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: false)))
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.probe(instances: twoInstances) == .noTarget)
    #expect(fallback.probeCalls == 0)
}

@Test func controllerNeverUsesFallbackWhenPrimaryFindsTheTarget() {
    let primary = StubBackend(probe: .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    let fallback = StubBackend(probe: .failed("nie powinno się wykonać"))
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.probe(instances: twoInstances) == .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    #expect(fallback.probeCalls == 0)
}

@Test func controllerFallsBackForActionsToo() {
    let primary = StubBackend(probe: .noTarget, action: .failed("ScriptingBridge padł"))
    let fallback = StubBackend(probe: .noTarget, action: .performed)
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.perform(.camera, instances: twoInstances) == .performed)
    #expect(fallback.performCalls == 1)
}

@Test func controllerNeverUsesFallbackForActionsWhenThereIsNoTarget() {
    let primary = StubBackend(probe: .noTarget, action: .noTarget)
    let fallback = StubBackend(probe: .noTarget, action: .performed)
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.perform(.microphone, instances: twoInstances) == .noTarget)
    #expect(fallback.performCalls == 0)
}

@Test func controllerWithoutFallbackReturnsPrimaryFailureUnchanged() {
    let primary = StubBackend(probe: .failed("brak zgody"))
    let controller = MeetController(primary: primary, fallback: nil)
    if case .failed(let message) = controller.probe(instances: twoInstances) {
        #expect(message == "brak zgody")
    } else {
        Issue.record("Oczekiwano .failed")
    }
}
