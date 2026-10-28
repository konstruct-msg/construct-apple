//
//  StudioProgramSenderTests.swift
//  ConstructMessengerTests
//
//  The host's program path without the capture: Float32 in, `ProgramPacket`s out
//  (`decisions/studio-mode-on-desktop.md`, step 3). Each test names the mutation that reddens it.
//

import SwiftProtobuf
import Synchronization
import XCTest
@testable import Construct_Messenger

final class StudioProgramSenderTests: XCTestCase {

    private let format = StudioAudioFormat.lossless

    private func packetize(_ feed: (StudioCapturePacketizer) -> Void) -> (StudioCapturePacketizer, [([Int32], UInt64)]) {
        let out = Mutex<[([Int32], UInt64)]>([])
        let packetizer = StudioCapturePacketizer(format: format) { samples, frame in out.withLock { $0.append((samples, frame)) } }
        feed(packetizer)
        return (packetizer, out.withLock { $0 })
    }

    /// A ramp a packet and a half long, then the rest: packets come out whole, numbered by the
    /// frame they start at, and a partial one waits for the next buffer.
    ///
    /// Mutation: never advance `nextFrame` — every packet claims frame 0; this reddens.
    func testPacketsAreWholeAndNumberedByTheirFirstFrame() {
        let frames = Int(format.framesPerPacket)
        let ramp = (0..<(frames * 3)).flatMap { f -> [Float] in
            let v = Float(f % 1000) / 1000
            return [v, -v]
        }
        let (_, out) = packetize { p in
            let split = Int(Double(frames) * 1.5) * 2
            ramp.withUnsafeBufferPointer { all in
                p.ingest(interleaved: UnsafeBufferPointer(rebasing: all[..<split]), channels: 2)
                p.ingest(interleaved: UnsafeBufferPointer(rebasing: all[split...]), channels: 2)
            }
        }
        XCTAssertEqual(out.map(\.1), [0, UInt64(frames), UInt64(frames * 2)])
        XCTAssertTrue(out.allSatisfy { $0.0.count == format.samplesPerPacket })
        let second = out[1].0
        let expected = Int32((Float(frames % 1000) / 1000 * studioSampleFullScale).rounded())
        XCTAssertEqual(second[0], expected, "left of the second packet's first frame")
        XCTAssertEqual(second[1], -expected, "right")
    }

    /// A mono source is heard on both sides.
    ///
    /// Mutation: take silence for the missing right channel — this reddens.
    func testAMonoSourceIsDuplicated() {
        let mono = [Float](repeating: 0.5, count: Int(format.framesPerPacket))
        let (_, out) = packetize { p in
            mono.withUnsafeBufferPointer { p.ingest(left: $0, right: nil) }
        }
        XCTAssertEqual(out.count, 1)
        let half = Int32((0.5 * studioSampleFullScale).rounded())
        XCTAssertTrue(out[0].0.allSatisfy { $0 == half })
    }

    /// Past full scale is clipped, and counted, never wrapped.
    ///
    /// Mutation: drop the clamp — 1.5 overflows 24 bits; this reddens.
    func testALoudSourceIsClippedAndCounted() {
        let loud = [Float](repeating: 1.5, count: format.samplesPerPacket)
        let (p, out) = packetize { p in
            loud.withUnsafeBufferPointer { p.ingest(interleaved: $0, channels: 2) }
        }
        XCTAssertEqual(p.clippedSamples, format.samplesPerPacket)
        XCTAssertTrue(out[0].0.allSatisfy { $0 == Int32(studioSampleFullScale) })
    }

    func testSilenceIsCounted() {
        let quiet = [Float](repeating: 0, count: format.samplesPerPacket)
        let (p, _) = packetize { p in quiet.withUnsafeBufferPointer { p.ingest(interleaved: $0, channels: 2) } }
        XCTAssertEqual(p.silentPackets, 1)
    }

    // MARK: - Sender

    private func packet(_ n: Int) -> [Int32] {
        (0..<format.samplesPerPacket).map { Int32((($0 * 7919 + n * 104_729) % 16_000_000) - 8_000_000) }
    }

    /// What the host sends is what the guest decodes, each packet numbered by the frames it holds,
    /// though FLAC releases nothing for the first packet given.
    ///
    /// Mutation: pair a released packet with the newest frame index instead of the oldest — this
    /// reddens.
    /// Mutation: never advance `sequence` — this reddens.
    func testTheProgramRoundTripsWithItsFrameNumbers() throws {
        var wire: [Data] = []
        let sender = try StudioProgramSender(format: format, epoch: 3) { wire.append($0); return true }
        let count = 12
        for n in 0..<count {
            try sender.submit(packet(n), firstFrame: UInt64(n) * UInt64(format.framesPerPacket))
        }
        XCTAssertGreaterThan(wire.count, 0)
        XCTAssertLessThan(wire.count, count, "the encoder holds input back")

        let packets = try wire.map { try StudioProgramPacket(serializedBytes: $0) }
        XCTAssertEqual(packets.map(\.sequence), (0..<UInt32(packets.count)).map { $0 })
        XCTAssertTrue(packets.allSatisfy { $0.formatEpoch == 3 })

        let decoder = try StudioAudioDecoder(format: format, magicCookie: sender.magicCookie)
        var decoded: [Int32] = []
        for p in packets { decoded += try decoder.decode(p.payload) }
        // The decoder may hold one back too; what it released must be the input from frame 0.
        let input = (0..<count).flatMap(packet)
        XCTAssertGreaterThan(decoded.count, 0)
        XCTAssertEqual(decoded, Array(input.prefix(decoded.count)))
        for (i, p) in packets.enumerated() {
            XCTAssertEqual(p.firstFrame, UInt64(i) * UInt64(format.framesPerPacket), "packet \(i)")
        }
        XCTAssertEqual(sender.sent, packets.count)
    }

    /// A channel that refuses is counted, not retried, and numbering goes on: the listener hears a
    /// gap, not a stall.
    func testARefusingChannelIsCounted() throws {
        let sender = try StudioProgramSender(format: format, epoch: 0) { _ in false }
        for n in 0..<6 { try sender.submit(packet(n), firstFrame: UInt64(n) * UInt64(format.framesPerPacket)) }
        XCTAssertGreaterThan(sender.refused, 0)
        XCTAssertEqual(sender.sent, 0)
    }
}
