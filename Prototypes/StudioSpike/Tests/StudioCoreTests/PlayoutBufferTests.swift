import XCTest
@testable import StudioCore

final class PlayoutBufferTests: XCTestCase {
    private func chunk(_ frames: Int, value: Int32) -> [Int32] { [Int32](repeating: value, count: frames * 2) }

    func testSilentUntilTheTargetDepthThenPlaysInOrder() {
        let b = PlayoutBuffer(channels: 2, sampleRate: 1000, targetSeconds: 0.1) // 100 frames
        var out = [Float](repeating: 1, count: 20)
        b.write(chunk(50, value: 1 << 22), firstFrame: 0)
        b.read(into: &out, frames: 10)
        XCTAssertEqual(out, [Float](repeating: 0, count: 20), "below the target: silence")
        b.write(chunk(50, value: 1 << 22), firstFrame: 50)
        b.read(into: &out, frames: 10)
        XCTAssertEqual(out, [Float](repeating: 0.5, count: 20))
        XCTAssertEqual(b.fillSeconds, 0.09, accuracy: 1e-9)
    }

    func testAForwardJumpIsFilledWithSilenceAndCounted() {
        let b = PlayoutBuffer(channels: 2, sampleRate: 1000, targetSeconds: 0.01)
        b.write(chunk(10, value: 7), firstFrame: 0)
        b.write(chunk(10, value: 7), firstFrame: 15)
        XCTAssertEqual(b.gapFrames, 5)
        XCTAssertEqual(b.fillSeconds, 0.025, accuracy: 1e-9)
    }

    func testARepeatedChunkIsIgnored() {
        let b = PlayoutBuffer(channels: 2, sampleRate: 1000, targetSeconds: 1)
        b.write(chunk(10, value: 7), firstFrame: 0)
        b.write(chunk(10, value: 7), firstFrame: 0)
        XCTAssertEqual(b.fillSeconds, 0.01, accuracy: 1e-9)
    }

    func testAnUnderrunIsCountedAndRearmsTheBuildUp() {
        let b = PlayoutBuffer(channels: 2, sampleRate: 1000, targetSeconds: 0.01)
        var out = [Float](repeating: 0, count: 40)
        b.write(chunk(10, value: 7), firstFrame: 0)
        b.read(into: &out, frames: 10)
        b.read(into: &out, frames: 10)
        XCTAssertEqual(b.underruns, 1)
        XCTAssertFalse(b.isPlaying)
    }

    func testSlopeOfALineIsItsGradient() {
        XCTAssertEqual(slope([(0, 1), (1, 1.5), (2, 2)])!, 0.5, accuracy: 1e-12)
        XCTAssertNil(slope([(0, 1)]))
    }
}
