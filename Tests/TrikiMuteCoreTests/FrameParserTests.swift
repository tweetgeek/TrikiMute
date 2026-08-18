import Foundation
import Testing
@testable import TrikiMuteCore

/// Builds a single 14-byte IMU frame with the given button state.
private func frame(pressed: Bool) -> [UInt8] {
    [0x22, pressed ? 0x01 : 0x00] + Array(repeating: 0x00, count: 12)
}

@Test func singleFrameYieldsOneState() {
    var parser = FrameParser()
    let out = parser.consume(frame(pressed: false), at: 1.0)
    #expect(out == [ButtonSample(pressed: false, timestamp: 1.0)])
}

@Test func pressedButtonIsRecognized() {
    var parser = FrameParser()
    let out = parser.consume(frame(pressed: true), at: 2.5)
    #expect(out == [ButtonSample(pressed: true, timestamp: 2.5)])
}

@Test func twoFramesJoinedInOneNotification() {
    var parser = FrameParser()
    let out = parser.consume(frame(pressed: false) + frame(pressed: true), at: 3.0)
    #expect(out.count == 2)
    #expect(out[0].pressed == false)
    #expect(out[1].pressed == true)
}

@Test func frameSplitAcrossNotificationBoundary() {
    var parser = FrameParser()
    let full = frame(pressed: true)
    let first = parser.consume(Array(full[0..<6]), at: 4.0)
    #expect(first.isEmpty)
    let second = parser.consume(Array(full[6...]), at: 4.1)
    #expect(second == [ButtonSample(pressed: true, timestamp: 4.1)])
}

@Test func garbageBeforeHeaderIsDiscarded() {
    var parser = FrameParser()
    let out = parser.consume([0xFF, 0xAB, 0x09] + frame(pressed: true), at: 5.0)
    #expect(out == [ButtonSample(pressed: true, timestamp: 5.0)])
}

@Test func unknownHeaderDoesNotBlockStream() {
    var parser = FrameParser()
    let garbage: [UInt8] = Array(repeating: 0x99, count: 40)
    _ = parser.consume(garbage, at: 6.0)
    let out = parser.consume(frame(pressed: false), at: 6.1)
    #expect(out == [ButtonSample(pressed: false, timestamp: 6.1)])
}

@Test func bufferDoesNotGrowUnbounded() {
    var parser = FrameParser()
    for i in 0..<200 {
        _ = parser.consume(Array(repeating: 0x99, count: 14), at: Double(i))
    }
    #expect(parser.bufferSize < 64)
}
