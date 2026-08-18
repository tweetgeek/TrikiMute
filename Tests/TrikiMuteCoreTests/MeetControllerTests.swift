import Foundation
import Testing
@testable import TrikiMuteCore

/// Fake executor: hands back programmed responses in order and remembers the
/// scripts it ran. The value "THROW" means that call should throw — this
/// lets us reproduce a situation where one browser fails while another
/// answers normally.
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

private struct RunnerError: Error {}

private final class ThrowingRunner: ScriptRunner {
    func run(_ source: String) throws -> String { throw RunnerError() }
}

@Test func probeReturnsNoTargetWhenNoBrowserHasMeet() {
    let runner = FakeRunner(["NONE", "NONE"])
    let c = MeetController(runner: runner)
    #expect(c.probe(browsers: ["Google Chrome", "Brave Browser"]) == .noTarget)
    #expect(runner.executed.count == 2)
}

@Test func probeDecodesMicAndCameraState() {
    // Response format: two characters, mic then camera, 1 = off.
    let runner = FakeRunner(["10"])
    let c = MeetController(runner: runner)
    let result = c.probe(browsers: ["Google Chrome"])
    #expect(result == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func probeStopsAtFirstBrowserWithTarget() {
    let runner = FakeRunner(["01", "11"])
    let c = MeetController(runner: runner)
    let result = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(result == .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    #expect(runner.executed.count == 1)
}

@Test func probeReportsErrorWhenRunnerThrows() {
    // The key distinction: a failure must not masquerade as no call in
    // progress, because the menu bar would then show "everything's fine"
    // while Automation access had actually been revoked.
    let c = MeetController(runner: ThrowingRunner())
    if case .failed = c.probe(browsers: ["Google Chrome"]) {
        // expected
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func probeFindsTargetDespiteFirstBrowserError() {
    let runner = FakeRunner(["THROW", "10"])
    let c = MeetController(runner: runner)
    let result = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(result == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func probeReportsErrorWhenOneBrowserThrowsAndOtherHasNoTarget() {
    let runner = FakeRunner(["THROW", "NONE"])
    let c = MeetController(runner: runner)
    if case .failed = c.probe(browsers: ["Brave Browser", "Google Chrome"]) {
        // expected
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

@Test func actionReportsNoTarget() {
    let runner = FakeRunner(["NONE"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .noTarget)
}

@Test func actionReportsSuccess() {
    let runner = FakeRunner(["OK"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .performed)
}

@Test func actionReportsRunnerError() {
    let c = MeetController(runner: ThrowingRunner())
    if case .failed = c.perform(.camera, browsers: ["Google Chrome"]) {
        // expected
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func actionSucceedsWhenFirstBrowserThrowsAndSecondWorks() {
    let runner = FakeRunner(["THROW", "OK"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Brave Browser", "Google Chrome"]) == .performed)
}

@Test func actionReportsErrorWhenOneBrowserThrowsAndOtherHasNoTarget() {
    let runner = FakeRunner(["THROW", "NONE"])
    let c = MeetController(runner: runner)
    if case .failed = c.perform(.microphone, browsers: ["Brave Browser", "Google Chrome"]) {
        // expected
    } else {
        Issue.record("Oczekiwano .failed, nie .noTarget")
    }
}

@Test func javascriptWithQuotesIsEscaped() {
    // appleScript() must be correct for arbitrary input, not rely on
    // generators sticking to apostrophes.
    let s = MeetScripts.appleScript(browser: "Google Chrome", javascript: "return \"x\"")
    #expect(s.contains("\\\"x\\\""))
}

@Test func microphoneAndCameraScriptsTargetDifferentIndices() {
    let mic = MeetScripts.toggleJS(.microphone)
    let cam = MeetScripts.toggleJS(.camera)
    #expect(mic != cam)
    #expect(mic.contains("[\(MeetScripts.micIndex)]"))
    #expect(cam.contains("[\(MeetScripts.cameraIndex)]"))
}

@Test func javascriptContainsNoQuotesThatWouldBreakAppleScript() {
    // The JS is inserted into an AppleScript string literal, so a double
    // quote would break the script. All JS must use apostrophes.
    #expect(!MeetScripts.probeJS().contains("\""))
    #expect(!MeetScripts.toggleJS(.microphone).contains("\""))
    #expect(!MeetScripts.toggleJS(.camera).contains("\""))
}

@Test func appleScriptContainsBrowserNameAndGuardConditions() {
    let s = MeetScripts.appleScript(browser: "Brave Browser", javascript: "1")
    #expect(s.contains("tell application \"Brave Browser\""))
    #expect(s.contains("if it is not running"))
    #expect(s.contains("meet.google.com"))
}

@Test func appleScriptLimitsExecutionTimeWithTimeout() {
    // Without this, a hung browser would block the script queue up to
    // AppleScript's default 60-second limit.
    let s = MeetScripts.appleScript(browser: "Google Chrome", javascript: "1")
    #expect(s.contains("with timeout of 5 seconds"))
    #expect(s.contains("end timeout"))
}
