//
//  StudioPlayoutOutput.swift
//  Construct Desktop
//
//  The guest's program, played (`decisions/studio-mode-on-desktop.md`, step 4): the playout ring
//  → AVAudioEngine source node → `AVAudioUnitVarispeed` → the default output. Varispeed is the
//  asynchronous rate conversion; `StudioDriftRegulator` sets its rate from the ring's fill so the
//  two sound cards' clocks stop mattering.
//
//  Once a minute the log says where the loop stands. Settled, the rate's departure from 1 is the
//  drift between the host's card and this one — the hour-long measurement the decision asks for
//  is that line, read over an hour.
//
//  The render block takes no lock and allocates nothing: the ring is lock-free, and the scratch
//  for a non-interleaved output is allocated here, once.
//

import AVFoundation
import Foundation

final class StudioPlayoutOutput: StudioProgramOutput {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let tickSeconds = 0.5
    static let logEverySeconds = 60.0
    /// Frames the scratch holds; a longer render is done in pieces of this size.
    private static let scratchFrames = 4_096

    private let playout: StudioPlayout
    private let engine = AVAudioEngine()
    private let varispeed = AVAudioUnitVarispeed()
    private let source: AVAudioSourceNode
    private let scratch: UnsafeMutablePointer<Float>
    private var regulator: StudioDriftRegulator
    private var timer: Timer?
    private var lastTick = Date()
    private var lastLog = Date()
    private var underrunsSeen = 0
    private var rate = 1.0

    static func make(playout: StudioPlayout) throws -> any StudioProgramOutput {
        try StudioPlayoutOutput(playout: playout)
    }

    /// On the main thread: the regulator's timer runs on its run loop.
    init(playout: StudioPlayout) throws {
        self.playout = playout
        regulator = StudioDriftRegulator(targetSeconds: Double(playout.targetFrames) / playout.sampleRate)
        let channels = playout.channels
        guard let format = AVAudioFormat(standardFormatWithSampleRate: playout.sampleRate,
                                         channels: AVAudioChannelCount(channels)) else {
            throw Failure(description: "no output format for \(channels) channels at \(playout.sampleRate) Hz")
        }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames * channels)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * channels)
        self.scratch = scratch

        // The ring is interleaved; the engine's standard format is one buffer per channel.
        source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            var done = 0
            let total = Int(frameCount)
            while done < total {
                let frames = min(Self.scratchFrames, total - done)
                playout.render(into: scratch, frames: frames)
                for (c, buffer) in buffers.enumerated() where c < channels {
                    guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for f in 0..<frames { out[done + f] = scratch[f * channels + c] }
                }
                done += frames
            }
            return noErr
        }

        engine.attach(source)
        engine.attach(varispeed)
        engine.connect(source, to: varispeed, format: format)
        engine.connect(varispeed, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            scratch.deallocate()
            throw error
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        engine.stop()
        log("stopped")
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        let underruns = playout.underruns
        if underruns > underrunsSeen {
            underrunsSeen = underruns
            regulator.refilled()
        }
        rate = regulator.update(fillSeconds: playout.fillSeconds, dt: dt)
        varispeed.rate = Float(rate)
        if now.timeIntervalSince(lastLog) >= Self.logEverySeconds {
            lastLog = now
            log("running")
        }
    }

    private func log(_ what: String) {
        let ppm = (rate - 1) * 1_000_000
        Log.info(
            "Studio playout \(what): fill \(Int(playout.fillSeconds * 1_000)) ms, rate \(String(format: "%+.1f", ppm)) ppm, "
            + "\(playout.underruns) underruns, \(playout.gapFrames) gap frames, \(playout.droppedSamples) dropped",
            category: "Calls"
        )
    }
}
