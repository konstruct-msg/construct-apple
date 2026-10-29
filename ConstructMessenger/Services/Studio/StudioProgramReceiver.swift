//
//  StudioProgramReceiver.swift
//  Construct Messenger
//
//  The guest's half of the program path (`decisions/studio-mode-on-desktop.md`, step 4): a
//  serialised `ProgramPacket` from the `studio-program` channel in, decoded 24-bit PCM into the
//  playout ring at the host's frame index. No output here — the Desktop plays `playout` — so the
//  whole path is testable on either platform.
//
//  What the decoder releases is placed by the frame indices of the packets given to it, oldest
//  first — the sender's pairing, mirrored. AudioToolbox's FLAC decoder releases each packet as it
//  is given (unlike its encoder), so today that queue holds one entry; it is kept for a decoder
//  that holds back, where placing by the packet just received would shift the program a packet.
//

import Foundation
import SwiftProtobuf
import Synchronization

final class StudioProgramReceiver: @unchecked Sendable {
    struct Unsupported: Error, CustomStringConvertible {
        var description: String { "a program format this build cannot play" }
    }

    struct Counts: Equatable, Sendable {
        var packets = 0
        /// Packets of another format epoch: in flight across a format change, dropped.
        var otherEpoch = 0
        var malformed = 0
        var undecodable = 0
    }

    let format: StudioAudioFormat
    let epoch: UInt32
    let playout: StudioPlayout

    private let decoder: StudioAudioDecoder
    private let queue = DispatchQueue(label: "studio.receive", qos: .userInitiated)
    private let counted = Mutex(Counts())

    // On `queue` only.
    /// First frames of the packets given to the decoder whose samples have not all come out.
    private var pending: [UInt64] = []
    /// Frames of `pending.first` already placed.
    private var placedOfHead = 0

    init(program: StudioProgramFormat, targetSeconds: Double) throws {
        guard let format = StudioAudioFormat(program: program) else { throw Unsupported() }
        self.format = format
        epoch = program.epoch
        decoder = try StudioAudioDecoder(format: format, magicCookie: program.magicCookie)
        playout = StudioPlayout(channels: Int(format.channels), sampleRate: Double(format.sampleRate),
                                targetSeconds: targetSeconds)
    }

    var counts: Counts { counted.withLock { $0 } }

    /// Any thread — WebRTC's, for the channel. Decoding happens on the receiver's own queue, in
    /// arrival order, which on the ordered channel is the host's.
    func receive(_ data: Data) {
        queue.async { self.take(data) }
    }

    /// Returns once every packet received so far has been placed.
    func settle() {
        queue.sync {}
    }

    private func take(_ data: Data) {
        guard let packet = try? StudioProgramPacket(serializedBytes: data) else {
            counted.withLock { $0.malformed += 1 }
            return
        }
        guard packet.formatEpoch == epoch else {
            counted.withLock { $0.otherEpoch += 1 }
            return
        }
        pending.append(packet.firstFrame)
        let samples: [Int32]
        do {
            samples = try decoder.decode(packet.payload)
        } catch {
            pending.removeLast()
            counted.withLock { $0.undecodable += 1 }
            return
        }
        counted.withLock { $0.packets += 1 }
        place(samples)
    }

    private func place(_ samples: [Int32]) {
        let channels = Int(format.channels)
        let framesPerPacket = Int(format.framesPerPacket)
        var offset = 0
        while offset < samples.count, let head = pending.first {
            let frames = min(framesPerPacket - placedOfHead, (samples.count - offset) / channels)
            guard frames > 0 else { break }
            let end = offset + frames * channels
            playout.write(Array(samples[offset..<end]), firstFrame: head + UInt64(placedOfHead))
            offset = end
            placedOfHead += frames
            if placedOfHead == framesPerPacket {
                pending.removeFirst()
                placedOfHead = 0
            }
        }
    }
}
