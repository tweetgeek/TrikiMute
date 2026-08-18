import Foundation

/// Assembles 14-byte IMU frames from the BLE notification stream and
/// extracts button state from them. Inertial data is discarded — TrikiMute
/// doesn't use it.
///
/// The device sends in bursts, so a single notification may contain multiple
/// frames or cut off mid-frame. The parser resynchronizes on the header.
public struct FrameParser {
    /// Length of a full IMU frame in bytes.
    private static let frameLength = 14
    /// First header byte. The second is the button flag: 0x00 or 0x01.
    private static let marker: UInt8 = 0x22

    private var buffer: [UInt8] = []

    public init() {}

    /// Size of the internal buffer. For resilience tests only.
    var bufferSize: Int { buffer.count }

    /// Appends bytes from one notification and returns the button states
    /// from every frame that could be assembled from them.
    public mutating func consume(_ bytes: [UInt8], at timestamp: TimeInterval) -> [ButtonSample] {
        buffer.append(contentsOf: bytes)
        var result: [ButtonSample] = []

        while true {
            guard let start = headerIndex() else {
                // Nothing that could be the start of a frame — keep only the
                // tail, which might still turn out to be the start of a marker.
                if buffer.count > Self.frameLength {
                    buffer.removeFirst(buffer.count - 1)
                }
                break
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= Self.frameLength else { break }

            result.append(ButtonSample(pressed: buffer[1] == 0x01, timestamp: timestamp))
            buffer.removeFirst(Self.frameLength)
        }

        return result
    }

    /// Index of the first byte from which a valid frame could start.
    private func headerIndex() -> Int? {
        for i in 0..<buffer.count where buffer[i] == Self.marker {
            // The second byte must be the button flag. If it isn't there yet,
            // wait for the next notification instead of discarding the marker.
            if i + 1 >= buffer.count { return i }
            if buffer[i + 1] == 0x00 || buffer[i + 1] == 0x01 { return i }
        }
        return nil
    }
}
