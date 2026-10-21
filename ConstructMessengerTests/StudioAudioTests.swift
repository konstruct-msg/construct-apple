//
//  StudioAudioTests.swift
//  ConstructMessengerTests
//
//  Studio mode's program-audio core: FLAC returns every sample bit for bit, Opus returns each
//  partial at its level, the playout ring keeps order and never blocks, and the drift loop holds
//  the buffer at its target against a constant clock mismatch.
//

import XCTest
@testable import Construct_Messenger

/// A deterministic stand-in for a mix: each sample is a function of its frame index alone, so
/// any stretch can be regenerated and compared. Three partials, a slow tremolo and noise around
/// -66 dBFS, so FLAC has something it can predict and something it cannot.
private func testSignal(firstFrame: UInt64, frames: Int, channels: Int = 2, sampleRate: Double = 48_000) -> [Int32] {
    var out = [Int32](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        let n = firstFrame + UInt64(f)
        let t = Double(n) / sampleRate
        let tremolo = 0.75 + 0.25 * sin(2 * .pi * 0.5 * t)
        for c in 0..<channels {
            let detune = 1 + 0.002 * Double(c)
            var x = 0.30 * sin(2 * .pi * 220 * detune * t) + 0.15 * sin(2 * .pi * 330.5 * detune * t)
                + 0.08 * sin(2 * .pi * 1_760 * t)
            x *= tremolo
            var z = (n &* 2 &+ UInt64(c)) &+ 0x9E37_79B9_7F4A_7C15
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            x += (Double(z >> 11) / Double(1 << 52) - 1) * 0.0005
            out[f * channels + c] = Int32((x * Double(studioSampleFullScale)).rounded())
        }
    }
    return out
}

final class StudioAudioCodecTests: XCTestCase {
    /// Encode `packets` packets and decode them as a stream: (sent, received, compressed bytes).
    private func roundTrip(_ format: StudioAudioFormat, packets: Int,
                           make: (Int) -> [Int32]) throws -> ([Int32], [Int32], Int) {
        let encoder = try StudioAudioEncoder(format: format)
        let decoder = try StudioAudioDecoder(format: format, magicCookie: try encoder.magicCookie())
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

    func testFlacReturnsTenSecondsOfMixBitForBit() throws {
        let format = StudioAudioFormat.lossless
        let packets = 48_000 * 10 / Int(format.framesPerPacket)
        let (sent, received, bytes) = try roundTrip(format, packets: packets) {
            testSignal(firstFrame: UInt64($0) * UInt64(format.framesPerPacket), frames: Int(format.framesPerPacket))
        }
        XCTAssertLessThanOrEqual(sent.count - received.count, 2 * format.samplesPerPacket,
                                 "the encoder holds back at most two packets")
        XCTAssertEqual(received, Array(sent.prefix(received.count)))
        let seconds = Double(received.count / 2) / format.sampleRate
        XCTAssertLessThan(Double(bytes * 8) / seconds, 2_304_000, "FLAC is smaller than 24-bit PCM")
    }

    func testFlacReturnsFullScaleExtremes() throws {
        let format = StudioAudioFormat.lossless
        let top = Int32((1 << 23) - 1), bottom = Int32(-(1 << 23))
        let (sent, received, _) = try roundTrip(format, packets: 4) { p in
            (0..<format.samplesPerPacket).map { ($0 + p) % 2 == 0 ? top : bottom }
        }
        XCTAssertFalse(received.isEmpty)
        XCTAssertEqual(received, Array(sent.prefix(received.count)))
    }

    /// Opus is not lossless, and it is not phase-coherent across bands either: measured here,
    /// 220 Hz and 1 760 Hz come back shifted by different amounts, so a waveform comparison
    /// reads about 10 dB at any alignment while each partial alone reads over 40. What a
    /// perceptual codec must return is the spectrum, so the check is the level of each partial.
    func testOpusAt510ReturnsEachPartialAtItsLevel() throws {
        let format = StudioAudioFormat.high
        let (sent, received, bytes) = try roundTrip(format, packets: 100) {
            testSignal(firstFrame: UInt64($0) * UInt64(format.framesPerPacket), frames: Int(format.framesPerPacket))
        }
        XCTAssertGreaterThan(received.count, sent.count * 9 / 10)
        let seconds = Double(received.count / 2) / format.sampleRate
        let bitRate = Double(bytes * 8) / seconds
        XCTAssertLessThan(bitRate, 560_000, "no more than the configured 510 kbit/s")
        XCTAssertGreaterThan(bitRate, 300_000, "the 510 kbit/s setting took effect (the default is far lower)")

        let left = { (s: [Int32]) in stride(from: 0, to: s.count, by: 2).map { Double(s[$0]) } }
        let a = Array(left(sent)[24_000..<33_600]), b = Array(left(received)[24_000..<33_600])
        for hz in [220.0, 330.5, 1_760.0] {
            let sentDb = 20 * log10(magnitude(a, hz: hz, sampleRate: format.sampleRate))
            let gotDb = 20 * log10(magnitude(b, hz: hz, sampleRate: format.sampleRate))
            XCTAssertEqual(gotDb, sentDb, accuracy: 0.5, "\(hz) Hz")
        }
    }

    /// Goertzel magnitude of one frequency over the window.
    private func magnitude(_ x: [Double], hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let k = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s0 = v + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        return sqrt(max(0, s1 * s1 + s2 * s2 - k * s1 * s2))
    }
}

final class StudioPlayoutTests: XCTestCase {
    private func chunk(_ frames: Int, _ value: Int32) -> [Int32] { [Int32](repeating: value, count: frames * 2) }

    func testRingKeepsOrderAcrossTheWrap() {
        let ring = StudioSampleRing(minimumCapacity: 8)
        var out = [Float](repeating: 0, count: 8)
        for round in 0..<5 {
            let input = (0..<6).map { Float(round * 10 + $0) }
            XCTAssertEqual(input.withUnsafeBufferPointer { ring.write($0) }, 6)
            XCTAssertEqual(ring.read(into: &out, count: 6), 6)
            XCTAssertEqual(Array(out.prefix(6)), input)
        }
    }

    func testAFullRingTakesOnlyWhatFits() {
        let ring = StudioSampleRing(minimumCapacity: 8)
        let first = (0..<6).map(Float.init), second = (6..<12).map(Float.init)
        XCTAssertEqual(first.withUnsafeBufferPointer { ring.write($0) }, 6)
        XCTAssertEqual(second.withUnsafeBufferPointer { ring.write($0) }, 2, "only the free part is taken")
        XCTAssertEqual(ring.count, 8)
        var out = [Float](repeating: -1, count: 8)
        XCTAssertEqual(ring.read(into: &out, count: 8), 8)
        XCTAssertEqual(out, (0..<8).map(Float.init), "nothing already written was overwritten")
    }

    func testSilentUntilTheTargetDepthThenPlaysTheSamples() {
        let p = StudioPlayout(channels: 2, sampleRate: 1_000, targetSeconds: 0.1)
        var out = [Float](repeating: 1, count: 20)
        p.write(chunk(50, 1 << 22), firstFrame: 0)
        p.render(into: &out, frames: 10)
        XCTAssertEqual(out, [Float](repeating: 0, count: 20), "below the target: silence")
        p.write(chunk(50, 1 << 22), firstFrame: 50)
        p.render(into: &out, frames: 10)
        for v in out { XCTAssertEqual(v, 0.5, accuracy: 1e-6) }
        XCTAssertEqual(p.fillSeconds, 0.09, accuracy: 1e-9)
    }

    func testAForwardJumpBecomesCountedSilence() {
        let p = StudioPlayout(channels: 2, sampleRate: 1_000, targetSeconds: 0.01)
        p.write(chunk(10, 7), firstFrame: 0)
        p.write(chunk(10, 7), firstFrame: 15)
        XCTAssertEqual(p.gapFrames, 5)
        XCTAssertEqual(p.fillSeconds, 0.025, accuracy: 1e-9)
    }

    func testARepeatedChunkIsIgnored() {
        let p = StudioPlayout(channels: 2, sampleRate: 1_000, targetSeconds: 1)
        p.write(chunk(10, 7), firstFrame: 0)
        p.write(chunk(10, 7), firstFrame: 0)
        XCTAssertEqual(p.fillSeconds, 0.01, accuracy: 1e-9)
    }

    func testAnUnderrunIsCountedAndRearmsTheBuildUp() {
        let p = StudioPlayout(channels: 2, sampleRate: 1_000, targetSeconds: 0.01)
        var out = [Float](repeating: 0, count: 40)
        p.write(chunk(10, 7), firstFrame: 0)
        p.render(into: &out, frames: 10)
        p.render(into: &out, frames: 10)
        XCTAssertEqual(p.underruns, 1)
        p.write(chunk(5, 7), firstFrame: 10)
        out = [Float](repeating: 1, count: 40)
        p.render(into: &out, frames: 5)
        XCTAssertEqual(Array(out.prefix(10)), [Float](repeating: 0, count: 10), "re-armed: waits for the target again")
    }

    func testAWriterThatOutrunsTheRingIsCounted() {
        let p = StudioPlayout(channels: 2, sampleRate: 1_000, targetSeconds: 0.01, capacitySeconds: 0.016)
        p.write(chunk(20, 7), firstFrame: 0) // 40 samples into a 32-sample ring
        XCTAssertEqual(p.droppedSamples, 8)
    }
}

final class StudioDriftRegulatorTests: XCTestCase {
    /// The host's card runs `ppm` fast relative to ours: audio arrives at (1 + ppm·10⁻⁶) seconds
    /// per second and leaves at the regulator's rate. Steps of one second.
    private func simulate(ppm: Double, minutes: Double, startFill: Double = 0.4) -> (fill: Double, rate: Double) {
        var r = StudioDriftRegulator(targetSeconds: 0.4)
        var fill = startFill, rate = 1.0
        for _ in 0..<Int(minutes * 60) {
            fill += (1 + ppm * 1e-6) - rate
            rate = r.update(fillSeconds: fill, dt: 1)
        }
        return (fill, rate)
    }

    func testAFastHostIsAbsorbedAndTheBufferHeldAtTarget() {
        let end = simulate(ppm: 80, minutes: 30)
        XCTAssertEqual(end.fill, 0.4, accuracy: 0.002)
        XCTAssertEqual(end.rate, 1 + 80e-6, accuracy: 5e-6, "plays as fast as the host sends")
    }

    func testASlowHostIsAbsorbedToo() {
        let end = simulate(ppm: -60, minutes: 30)
        XCTAssertEqual(end.fill, 0.4, accuracy: 0.002)
        XCTAssertLessThan(end.rate, 1)
    }

    func testAnOverfullBufferPlaysFasterWithinTheClamp() {
        var r = StudioDriftRegulator(targetSeconds: 0.4)
        let rate = r.update(fillSeconds: 2.0, dt: 1)
        XCTAssertGreaterThan(rate, 1)
        XCTAssertLessThanOrEqual(rate, 1 + 500e-6)
    }

    func testNoDriftLeavesTheRateAlone() {
        let end = simulate(ppm: 0, minutes: 10)
        XCTAssertEqual(end.rate, 1, accuracy: 1e-9)
    }
}
