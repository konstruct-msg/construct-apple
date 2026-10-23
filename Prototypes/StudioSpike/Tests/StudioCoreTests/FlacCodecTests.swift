import XCTest
@testable import StudioCore

final class FlacCodecTests: XCTestCase {
    /// Encode and decode `packets` packets of `make`, as streams; returns (sent, received, FLAC bytes).
    private func roundTrip(packets: Int, format: AudioFormat = AudioFormat(),
                           make: (Int) -> [Int32]) throws -> ([Int32], [Int32], Int) {
        let encoder = try FlacEncoder(format: format)
        let decoder = try FlacDecoder(format: format, magicCookie: try encoder.magicCookie())
        var sent: [Int32] = [], received: [Int32] = [], bytes = 0
        for p in 0..<packets {
            let input = make(p)
            sent += input
            for packet in try encoder.encode(input) {
                bytes += packet.count
                received += try decoder.decode(packet)
            }
        }
        return (sent, received, bytes)
    }

    func testTenSecondsOfTheTestSignalSurviveFlacBitForBit() throws {
        let format = AudioFormat()
        let packets = Int(10 * format.sampleRate) / Int(format.framesPerPacket)
        let (sent, received, bytes) = try roundTrip(packets: packets) {
            TestSignal.samples(firstFrame: UInt64($0) * UInt64(format.framesPerPacket), format: format)
        }
        // The encoder holds packets back; everything it released must match the start of what was sent.
        let held = sent.count - received.count
        XCTAssertLessThanOrEqual(held, 2 * format.samplesPerPacket, "encoder holds at most two packets")
        XCTAssertEqual(received, Array(sent.prefix(received.count)))
        let kbps = Double(bytes * 8) / (Double(received.count / 2) / format.sampleRate) / 1000
        XCTAssertLessThan(kbps, 2304, "FLAC must be smaller than 24-bit PCM")
        print("FLAC test signal: \(Int(kbps)) kbit/s, encoder holds \(held / Int(format.channels)) frames")
    }

    func testFullScaleExtremesSurvive() throws {
        let format = AudioFormat()
        let max = Int32((1 << 23) - 1), min = Int32(-(1 << 23))
        let (sent, received, _) = try roundTrip(packets: 4) { p in
            (0..<format.samplesPerPacket).map { ($0 + p) % 2 == 0 ? max : min }
        }
        XCTAssertFalse(received.isEmpty)
        XCTAssertEqual(received, Array(sent.prefix(received.count)))
    }

    func testTheTestSignalIsAFunctionOfTheIndexAlone() {
        let format = AudioFormat()
        let whole = TestSignal.samples(firstFrame: 0, format: AudioFormat(framesPerPacket: 2048))
        let second = TestSignal.samples(firstFrame: 1024, format: format)
        XCTAssertEqual(Array(whole[2048...]), second)
    }
}
