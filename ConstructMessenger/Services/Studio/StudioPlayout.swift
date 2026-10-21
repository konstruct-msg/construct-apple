//
//  StudioPlayout.swift
//  Construct Messenger
//
//  The listener's program buffer for studio mode: decoded samples keyed by the host's frame
//  index go in from the network side, Float32 comes out on the audio render thread.
//
//  The render thread takes no lock and allocates nothing: the samples sit in a single-producer,
//  single-consumer ring whose two indices are atomics. Everything that needs bookkeeping — where
//  the next frame belongs, a gap the sender left, a repeat — happens on the writer's side.
//
//  It does not resample. Two sound cards never run at exactly the same rate, so the fill level
//  creeps; `StudioDriftRegulator` reads `fillSeconds` and sets the playback rate that holds it.
//

import Foundation
import Synchronization

/// Single-producer, single-consumer ring of Float32 samples. `write` from one thread, `read` from
/// one other thread; neither blocks. Indices count samples ever written and read, so the fill is
/// their difference and wrap-around is a mask.
final class StudioSampleRing: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    /// `minimumCapacity` samples, rounded up to a power of two.
    init(minimumCapacity: Int) {
        var c = 1
        while c < minimumCapacity { c <<= 1 }
        capacity = c
        mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit { storage.deallocate() }

    /// Samples waiting to be read.
    var count: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }

    /// Writer side. Returns how many were taken — fewer than offered when the ring is full.
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let w = written.load(ordering: .relaxed)
        let r = consumed.load(ordering: .acquiring)
        let n = min(samples.count, capacity - (w - r))
        for i in 0..<n { storage[(w + i) & mask] = samples[i] }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Reader side. Copies up to `count` samples into `out`; returns how many.
    func read(into out: UnsafeMutablePointer<Float>, count wanted: Int) -> Int {
        let r = consumed.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        let n = min(wanted, w - r)
        for i in 0..<n { out[i] = storage[(r + i) & mask] }
        consumed.store(r + n, ordering: .releasing)
        return n
    }
}

final class StudioPlayout: @unchecked Sendable {
    let channels: Int
    let sampleRate: Double
    /// Depth built up before the first sample plays, and again after an underrun.
    let targetFrames: Int

    private let ring: StudioSampleRing
    private let underrunCount = Atomic<Int>(0)
    private let droppedCount = Atomic<Int>(0)

    // Writer side only.
    private var nextFrame: UInt64?
    private var scratch: [Float] = []
    private(set) var gapFrames: UInt64 = 0

    // Render side only.
    private var playing = false

    /// `capacitySeconds` bounds the ring; a writer that outruns it loses the excess (counted).
    init(channels: Int, sampleRate: Double, targetSeconds: Double, capacitySeconds: Double = 4) {
        self.channels = channels
        self.sampleRate = sampleRate
        targetFrames = Int(targetSeconds * sampleRate)
        ring = StudioSampleRing(minimumCapacity: Int(capacitySeconds * sampleRate) * channels)
    }

    var underruns: Int { underrunCount.load(ordering: .relaxed) }
    /// Samples refused because the ring was full.
    var droppedSamples: Int { droppedCount.load(ordering: .relaxed) }
    var fillSeconds: Double { Double(ring.count / channels) / sampleRate }

    /// Writer side. `chunk` is interleaved 24-bit PCM whose first frame is `firstFrame` on the
    /// host's capture clock. The stream is ordered, so a jump forward is a packet the sender
    /// dropped: it becomes silence, counted in `gapFrames`. A chunk at or behind the write
    /// position is a repeat and is ignored.
    func write(_ chunk: [Int32], firstFrame: UInt64) {
        let frames = UInt64(chunk.count / channels)
        if let expected = nextFrame {
            if firstFrame + frames <= expected { return }
            if firstFrame > expected {
                let gap = firstFrame - expected
                gapFrames += gap
                push([Float](repeating: 0, count: Int(gap) * channels))
            }
        }
        scratch.removeAll(keepingCapacity: true)
        let scale = 1 / studioSampleFullScale
        for s in chunk { scratch.append(Float(s) * scale) }
        push(scratch)
        nextFrame = firstFrame + frames
    }

    private func push(_ samples: [Float]) {
        let taken = samples.withUnsafeBufferPointer { ring.write($0) }
        if taken < samples.count { droppedCount.add(samples.count - taken, ordering: .relaxed) }
    }

    /// Render side. Fills `frames` interleaved frames: silence until the target depth is reached,
    /// and on an underrun, which also re-arms the build-up so playback resumes with headroom.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let wanted = frames * channels
        if !playing {
            if ring.count >= targetFrames * channels {
                playing = true
            } else {
                out.update(repeating: 0, count: wanted)
                return
            }
        }
        let got = ring.read(into: out, count: wanted)
        if got < wanted {
            (out + got).update(repeating: 0, count: wanted - got)
            playing = false
            underrunCount.add(1, ordering: .relaxed)
        }
    }
}
