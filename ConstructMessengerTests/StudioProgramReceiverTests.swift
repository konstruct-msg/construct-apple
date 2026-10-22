//
//  StudioProgramReceiverTests.swift
//  ConstructMessengerTests
//
//  The guest's program path without the output: what the host's sender put on the wire comes out
//  of the playout ring as the host's samples, at the host's frame indices
//  (`decisions/studio-mode-on-desktop.md`, step 4). Each test names the mutation that reddens it.
//

import SwiftProtobuf
import XCTest
@testable import Construct_Messenger

final class StudioProgramReceiverTests: XCTestCase {

    private let format = StudioAudioFormat.lossless
    private var frames: Int { Int(format.framesPerPacket) }

    private func packet(_ n: Int) -> [Int32] {
        (0..<format.samplesPerPacket).map { Int32((($0 * 7919 + n * 104_729) % 16_000_000) - 8_000_000) }
    }

    /// The host's side: `count` packets through the sender, what it put on the wire.
    private func wire(count: Int, epoch: UInt32 = 0) throws -> (packets: [Data], cookie: Data) {
        var out: [Data] = []
        let sender = try StudioProgramSender(format: format, epoch: epoch) { out.append($0); return true }
        for n in 0..<count {
            try sender.submit(packet(n), firstFrame: UInt64(n * frames))
        }
        return (out, sender.magicCookie)
    }

    private func receiver(cookie: Data, epoch: UInt32 = 0, targetSeconds: Double = 0.001) throws -> StudioProgramReceiver {
        var program = format.program(magicCookie: cookie)
        program.epoch = epoch
        return try StudioProgramReceiver(program: program, targetSeconds: targetSeconds)
    }

    /// Everything in the ring, as the render thread would take it.
    private func rendered(_ r: StudioProgramReceiver) -> [Float] {
        let n = r.playout.fillSeconds * r.playout.sampleRate
        let samples = Int(n.rounded()) * r.playout.channels
        var out = [Float](repeating: 0, count: samples)
        out.withUnsafeMutableBufferPointer { r.playout.render(into: $0.baseAddress!, frames: Int(n.rounded())) }
        return out
    }

    private func floats(_ samples: [Int32]) -> [Float] {
        samples.map { Float($0) * (1 / studioSampleFullScale) }
    }

    /// The program arrives whole: what plays is what the host captured, from frame 0, though the
    /// encoder holds a packet back.
    ///
    /// Not a check of the receiver's oldest-first pairing: AudioToolbox's FLAC decoder releases
    /// each packet as it is given, so oldest and newest are one entry (mutation run 2026-10-22).
    /// The pairing is there for a decoder that does hold back.
    func testWhatPlaysIsWhatTheHostCaptured() throws {
        let (packets, cookie) = try wire(count: 12)
        let r = try receiver(cookie: cookie)
        packets.forEach(r.receive)
        r.settle()

        let played = rendered(r)
        XCTAssertGreaterThan(played.count, 0)
        XCTAssertEqual(played, Array(floats((0..<12).flatMap(packet)).prefix(played.count)))
        XCTAssertEqual(r.playout.gapFrames, 0)
        XCTAssertEqual(r.counts.packets, packets.count)
    }

    /// A packet the channel lost is a gap of its length in silence, and the program goes on at the
    /// right place after it.
    ///
    /// Mutation: write released samples at the next free position instead of their own frame —
    /// the gap closes up and everything after it plays a packet early; this reddens.
    func testALostPacketIsHeardAsAGapOfItsLength() throws {
        let (packets, cookie) = try wire(count: 12)
        let r = try receiver(cookie: cookie)
        let lost = 4
        for (i, p) in packets.enumerated() where i != lost { r.receive(p) }
        r.settle()

        XCTAssertEqual(r.playout.gapFrames, UInt64(frames))
        let played = rendered(r)
        let slot = lost * format.samplesPerPacket
        let expected = (0..<12).flatMap { n in n == lost ? [Int32](repeating: 0, count: format.samplesPerPacket) : packet(n) }
        let checked = min(played.count, slot + 2 * format.samplesPerPacket)
        XCTAssertGreaterThan(checked, slot + format.samplesPerPacket, "the packet after the gap was played")
        XCTAssertEqual(Array(played.prefix(checked)), Array(floats(expected).prefix(checked)))
    }

    /// A packet of another format epoch — in flight across a format change — is dropped and
    /// counted, never decoded with the wrong decoder.
    ///
    /// Mutation: drop the epoch check — the packets are decoded and played; this reddens.
    func testAPacketOfAnotherFormatIsDropped() throws {
        let (old, _) = try wire(count: 4, epoch: 0)
        let (_, cookie) = try wire(count: 1, epoch: 1)
        let r = try receiver(cookie: cookie, epoch: 1)
        old.forEach(r.receive)
        r.settle()

        XCTAssertEqual(r.counts.otherEpoch, old.count)
        XCTAssertEqual(r.counts.packets, 0)
        XCTAssertEqual(r.playout.fillSeconds, 0)
    }

    func testBytesThatAreNoPacketAreCounted() throws {
        let (_, cookie) = try wire(count: 1)
        let r = try receiver(cookie: cookie)
        r.receive(Data([0xFF, 0xFF, 0xFF]))
        r.settle()
        XCTAssertEqual(r.counts.malformed, 1)
    }

    /// A format this build cannot play is refused before anything is made for it.
    func testAFormatThisBuildCannotPlayIsRefused() {
        var program = format.program(magicCookie: Data())
        program.sampleRate = 96_000
        XCTAssertThrowsError(try StudioProgramReceiver(program: program, targetSeconds: 0.4))
    }

    /// The invite's depth is taken within bounds; none means the default.
    ///
    /// Mutation: take the invite's value unbounded — 60 s holds the program back a minute; this
    /// reddens.
    func testTheBufferDepthIsBounded() {
        XCTAssertEqual(StudioBuffer.targetSeconds(invite: 0), Double(StudioBuffer.defaultMs) / 1_000)
        XCTAssertEqual(StudioBuffer.targetSeconds(invite: 400), 0.4)
        XCTAssertEqual(StudioBuffer.targetSeconds(invite: 60_000), 2)
        XCTAssertEqual(StudioBuffer.targetSeconds(invite: 5), 0.1)
    }
}
