import Foundation
import Testing
@testable import TrikiMuteCore

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
