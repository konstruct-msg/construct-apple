import AVFoundation
import StudioCore

/// Plays a `PlayoutBuffer` on the default output. AVAudioEngine converts to the device's rate if
/// it differs from the stream's — a resample this spike does not measure; the bit-exactness check
/// is made before it, on the decoded samples.
public final class ProgramOutput {
    private let engine = AVAudioEngine()
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 8192

    public init(buffer: PlayoutBuffer) throws {
        let channels = buffer.channels
        scratch = .allocate(capacity: scratchFrames * channels)
        let format = AVAudioFormat(standardFormatWithSampleRate: buffer.sampleRate,
                                   channels: AVAudioChannelCount(channels))!
        let scratch = self.scratch
        let maxFrames = scratchFrames
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, list in
            let frames = min(Int(frameCount), maxFrames)
            buffer.read(into: scratch, frames: frames)
            let abl = UnsafeMutableAudioBufferListPointer(list)
            for (c, b) in abl.enumerated() where c < channels {
                let out = b.mData!.assumingMemoryBound(to: Float.self)
                for f in 0..<frames { out[f] = scratch[f * channels + c] }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    deinit {
        engine.stop()
        scratch.deallocate()
    }
}
