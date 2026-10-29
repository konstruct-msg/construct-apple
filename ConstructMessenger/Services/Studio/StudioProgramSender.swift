//
//  StudioProgramSender.swift
//  Construct Messenger
//
//  The host's half of the program path (`decisions/studio-mode-on-desktop.md`, step 3): captured
//  Float32 is cut into packets of the format's size and quantised to 24 bits, encoded, and wrapped
//  in `ProgramPacket`s for the `studio-program` channel. No capture here — the Desktop process tap
//  feeds it — so the whole path is testable on either platform.
//

import Foundation
import SwiftProtobuf

typealias StudioProgramPacket = Construct_Client_Studio_V1_ProgramPacket

/// Captured audio in, packets of exactly `format.samplesPerPacket` 24-bit samples out, each with
/// the frame index of its first frame on the capture clock (counted from the first frame given).
/// Stereo out whatever comes in: a mono source is duplicated, channels past the second dropped.
final class StudioCapturePacketizer {
    let format: StudioAudioFormat
    /// Samples outside ±1 before clipping — the program was too loud at the source.
    private(set) var clippedSamples = 0
    private(set) var packets = 0
    /// Packets that were all zero: what a process tap delivers without the capture permission.
    private(set) var silentPackets = 0

    private var pending: [Int32]
    private var filled = 0
    private var nextFrame: UInt64 = 0
    /// Called on the capture's thread — Core Audio's I/O thread. `@Sendable`, so a callback made
    /// in a main-actor method is not isolated to the main actor: Swift 6 traps when an isolated
    /// closure runs off its actor (Desktop 0.3.17 crashed on the first packet, 2026-10-28).
    private let onPacket: @Sendable ([Int32], UInt64) -> Void

    init(format: StudioAudioFormat, onPacket: @escaping @Sendable ([Int32], UInt64) -> Void) {
        precondition(format.channels == 2, "the program is stereo")
        self.format = format
        self.onPacket = onPacket
        pending = [Int32](repeating: 0, count: format.samplesPerPacket)
    }

    /// Interleaved frames of `channels` channels.
    func ingest(interleaved samples: UnsafeBufferPointer<Float>, channels: Int) {
        guard channels > 0 else { return }
        let frames = samples.count / channels
        for f in 0..<frames {
            push(samples[f * channels], samples[f * channels + min(1, channels - 1)])
        }
    }

    /// One buffer per channel; `right` nil for a mono source.
    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>?) {
        let right = right ?? left
        for f in 0..<min(left.count, right.count) {
            push(left[f], right[f])
        }
    }

    private func push(_ l: Float, _ r: Float) {
        pending[filled] = quantise(l)
        pending[filled + 1] = quantise(r)
        filled += 2
        guard filled == pending.count else { return }
        packets += 1
        if pending.allSatisfy({ $0 == 0 }) { silentPackets += 1 }
        onPacket(pending, nextFrame)
        nextFrame += UInt64(format.framesPerPacket)
        filled = 0
    }

    private func quantise(_ x: Float) -> Int32 {
        if x > 1 || x < -1 { clippedSamples += 1 }
        return Int32((max(-1, min(1, x)) * studioSampleFullScale).rounded())
    }
}

/// Encodes packets and hands each encoded one over as a serialised `ProgramPacket`.
///
/// The encoder holds input back (FLAC releases nothing for the first packet), so what it releases
/// is paired with the frame indices it was given, oldest first: a released packet is the oldest
/// queued input that has not come out yet.
final class StudioProgramSender {
    let format: StudioAudioFormat
    let epoch: UInt32
    /// What the receiver's decoder needs before the first packet; goes in the invite.
    let magicCookie: Data
    private(set) var sent = 0
    /// Packets the channel refused (not open, or WebRTC's queue full). The program is never thinned
    /// on purpose; a refusal is a gap the listener hears as silence.
    private(set) var refused = 0

    private let encoder: StudioAudioEncoder
    private var queuedFrames: [UInt64] = []
    private var sequence: UInt32 = 0
    private let send: (Data) -> Bool

    init(format: StudioAudioFormat, epoch: UInt32, send: @escaping (Data) -> Bool) throws {
        self.format = format
        self.epoch = epoch
        self.send = send
        encoder = try StudioAudioEncoder(format: format)
        magicCookie = try encoder.magicCookie()
    }

    /// One packet of `format.samplesPerPacket` samples, and the capture frame index of its first frame.
    func submit(_ samples: [Int32], firstFrame: UInt64) throws {
        queuedFrames.append(firstFrame)
        for payload in try encoder.encode(samples) {
            guard !queuedFrames.isEmpty else { break }
            var packet = StudioProgramPacket()
            packet.sequence = sequence
            packet.firstFrame = queuedFrames.removeFirst()
            packet.formatEpoch = epoch
            packet.payload = payload
            sequence &+= 1
            if send(try packet.serializedData()) { sent += 1 } else { refused += 1 }
        }
    }
}
