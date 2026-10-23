import XCTest
@testable import StudioCore

final class StudioFrameTests: XCTestCase {
    func testAudioFrameRoundTrips() throws {
        let f = StudioFrame(kind: .audio, frames: 1024, sequence: 7, firstFrame: 1 << 40, sentAtNanos: 123_456_789,
                            sampleRate: 48_000, channels: 2, payload: Data([1, 2, 3]))
        XCTAssertEqual(try StudioFrame(decoding: f.encoded()), f)
    }

    func testConfigCarriesFormatAndCookie() throws {
        let c = StreamConfig(format: AudioFormat(sampleRate: 44_100, framesPerPacket: 512), magicCookie: Data([9, 8, 7]))
        let back = try StreamConfig(frame: try StudioFrame(decoding: c.frame(sentAtNanos: 1).encoded()))
        XCTAssertEqual(back, c)
    }

    func testForeignVersionIsRefused() {
        var d = StudioFrame(kind: .audio, frames: 1, sequence: 0, firstFrame: 0, sentAtNanos: 0, sampleRate: 48_000,
                            channels: 2, payload: Data()).encoded()
        d[0] = 2
        XCTAssertThrowsError(try StudioFrame(decoding: d)) { XCTAssertEqual($0 as? StudioFrame.DecodeError, .version(2)) }
    }
}
