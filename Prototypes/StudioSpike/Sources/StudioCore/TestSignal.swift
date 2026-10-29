import Foundation

/// A deterministic stand-in for a mix: any sample is a pure function of its index, so a receiver
/// can regenerate what the sender sent and compare bit for bit without the two sharing anything
/// but the index. Three partials, a slow tremolo and noise around -66 dBFS, so FLAC has something
/// to predict and something it cannot.
public enum TestSignal {
    public static func samples(firstFrame: UInt64, format: AudioFormat) -> [Int32] {
        let channels = Int(format.channels)
        var out = [Int32](repeating: 0, count: format.samplesPerPacket)
        let peak = Double(1 << 23) - 1
        for f in 0..<Int(format.framesPerPacket) {
            let n = firstFrame + UInt64(f)
            let t = Double(n) / format.sampleRate
            let tremolo = 0.75 + 0.25 * sin(2 * .pi * 0.5 * t)
            for c in 0..<channels {
                let detune = 1 + 0.002 * Double(c)
                var x = 0.30 * sin(2 * .pi * 220 * detune * t)
                x += 0.15 * sin(2 * .pi * 330.5 * detune * t)
                x += 0.08 * sin(2 * .pi * 1_760 * t)
                x *= tremolo
                x += noise(n &* 2 &+ UInt64(c)) * 0.0005
                out[f * channels + c] = Int32((x * peak).rounded())
            }
        }
        return out
    }

    /// splitmix64 of the index → [-1, 1).
    private static func noise(_ index: UInt64) -> Double {
        var z = index &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 52) - 1
    }
}
