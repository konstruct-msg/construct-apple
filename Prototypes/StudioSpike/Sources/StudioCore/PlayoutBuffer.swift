import Foundation

/// The receiver's program buffer: decoded samples keyed by the host's frame index, read out by the
/// output device's clock.
///
/// It does not resample. Two sound cards never run at exactly the same rate, so the fill level
/// creeps up or down; `fillSeconds` sampled over time is the drift measurement (the slope, in
/// seconds per second, times 10^6 is ppm) that sizes the ASRC the real path will need. Until then
/// a run is short enough that the creep fits inside the target depth.
///
/// Thread-safe: `write` comes from the network, `read` from the audio render thread. The render
/// side takes a lock — acceptable in a spike, not in the product.
public final class PlayoutBuffer: @unchecked Sendable {
    public let channels: Int
    public let sampleRate: Double
    /// Depth to build up before the first sample is played.
    public let targetFrames: Int

    private let lock = NSLock()
    private var samples: [Int32] = []
    private var readIndex = 0
    /// Host frame index of `samples[readIndex]`'s frame, once the first write arrives.
    private var headFrame: UInt64?
    private var playing = false

    public private(set) var underruns = 0
    public private(set) var gapFrames: UInt64 = 0
    public private(set) var framesPlayed: UInt64 = 0

    public init(channels: Int, sampleRate: Double, targetSeconds: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.targetFrames = Int(targetSeconds * sampleRate)
    }

    /// Append decoded samples whose first frame is `firstFrame` on the host's clock. The stream is
    /// ordered and reliable, so a jump forward is a gap the sender made (it dropped a packet under
    /// backpressure); it is filled with silence and counted, never reordered.
    public func write(_ chunk: [Int32], firstFrame: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let frames = UInt64(chunk.count / channels)
        if headFrame == nil { headFrame = firstFrame }
        let expected = headFrame! + UInt64((samples.count - readIndex) / channels)
        if firstFrame > expected {
            let gap = firstFrame - expected
            gapFrames += gap
            samples += [Int32](repeating: 0, count: Int(gap) * channels)
        } else if firstFrame + frames <= expected {
            return // already have it
        }
        samples += chunk
        if !playing, (samples.count - readIndex) / channels >= targetFrames { playing = true }
        compact()
    }

    /// Fill `out` (interleaved Float32, `frames` frames) for the device. Silence until the target
    /// depth is first reached, and on an underrun, which also re-arms the build-up.
    public func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let wanted = frames * channels
        let available = samples.count - readIndex
        guard playing, available >= wanted else {
            if playing { underruns += 1; playing = false }
            out.update(repeating: 0, count: wanted)
            return
        }
        let scale = 1 / Float(1 << 23)
        for i in 0..<wanted { out[i] = Float(samples[readIndex + i]) * scale }
        readIndex += wanted
        headFrame! += UInt64(frames)
        framesPlayed += UInt64(frames)
    }

    public var fillSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double((samples.count - readIndex) / channels) / sampleRate
    }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return playing
    }

    private func compact() {
        if readIndex > 1 << 20 {
            samples.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

/// Least-squares slope of (t, y) — fill level against time gives the drift.
public func slope(_ points: [(Double, Double)]) -> Double? {
    guard points.count >= 2 else { return nil }
    let n = Double(points.count)
    let mx = points.map(\.0).reduce(0, +) / n
    let my = points.map(\.1).reduce(0, +) / n
    let sxy = points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
    let sxx = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
    return sxx > 0 ? sxy / sxx : nil
}

/// Percentile of a sample, nearest-rank.
public func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
    return sorted[max(0, min(sorted.count - 1, rank))]
}
