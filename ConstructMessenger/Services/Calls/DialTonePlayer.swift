// DialTonePlayer.swift
// Construct Messenger
//
// Synthesizes a dialup-modem-inspired ringback tone for outgoing calls.
// Signal: mix of V.21 FSK mark (1850 Hz) and space (1650 Hz) tones,
// AM-modulated at 15 Hz to evoke modem carrier negotiation.
// Pattern: 2 s tone / 1 s silence, looping.

#if os(iOS)
import AVFoundation

@MainActor
final class DialTonePlayer {
    static let shared = DialTonePlayer()

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var cycleBuffer: AVAudioPCMBuffer?
    private(set) var isPlaying = false

    private let sampleRate: Double = 44100

    private init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            preconditionFailure("DialTonePlayer: AVAudioFormat init failed for 44100Hz/1ch — should never happen")
        }
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        cycleBuffer = makeCycleBuffer(format: format)
    }

    /// Start the tone. Must be called after CallKit activates the audio session.
    func start() {
        guard !isPlaying, let buffer = cycleBuffer else { return }
        do {
            if !engine.isRunning { try engine.start() }
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops)
            playerNode.play()
            isPlaying = true
            Log.info("📞 Dial tone started", category: "Calls")
        } catch {
            Log.error("📞 DialTonePlayer: engine start failed: \(error)", category: "Calls")
        }
    }

    func stop() {
        guard isPlaying else { return }
        playerNode.stop()
        engine.stop()
        isPlaying = false
        Log.info("📞 Dial tone stopped", category: "Calls")
    }

    // MARK: - PCM synthesis

    private func makeCycleBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // 2 s audible tone + 1 s silence = one 3 s cycle
        let toneSeconds = 2.0
        let totalSeconds = 3.0
        let toneFrames  = Int(toneSeconds * sampleRate)
        let totalFrames = AVAudioFrameCount(totalSeconds * sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let data = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = totalFrames

        let twoPi = 2.0 * Double.pi
        // 20 ms linear fade at each tone edge to avoid clicks
        let fadeFrames = Int(0.02 * sampleRate)

        for i in 0..<Int(totalFrames) {
            guard i < toneFrames else {
                data[i] = 0
                continue
            }
            let t = Double(i) / sampleRate

            // V.21 FSK tones: space (1650 Hz) + mark (1850 Hz)
            let s1 = sin(twoPi * 1650.0 * t)
            let s2 = sin(twoPi * 1850.0 * t)

            // AM modulation at 15 Hz — modem carrier-lock texture
            let am = (1.0 + sin(twoPi * 15.0 * t)) * 0.5

            let fadeIn  = i < fadeFrames ? Double(i) / Double(fadeFrames) : 1.0
            let fadeOut = i > toneFrames - fadeFrames
                        ? Double(toneFrames - i) / Double(fadeFrames) : 1.0

            data[i] = Float((s1 + s2) * 0.5 * am * 0.25 * fadeIn * fadeOut)
        }
        return buffer
    }
}
#endif
