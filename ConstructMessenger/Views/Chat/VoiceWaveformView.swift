import SwiftUI
import Combine

struct VoiceWaveformView: View {
    enum Style {
        case playback(progress: Double, isSentByMe: Bool)
        case staticAccent(opacity: Double = 0.7)
        case liveInput
    }

    let samples: [Float]
    let style: Style

    /// Preferred bar count. Used as a ceiling — the actual number rendered is
    /// reduced when the available width can't hold that many bars at the
    /// minimum bar width, preventing the HStack from overflowing past the
    /// view's frame (which used to make the rightmost bars sit on top of
    /// neighbouring controls in the message bubble).
    private let preferredBarCount = 64
    private let barSpacing: CGFloat = 2.0

    var body: some View {
        GeometryReader { geo in
            let barCount = effectiveBarCount(for: geo.size.width)
            let totalSpacing = barSpacing * CGFloat(max(barCount - 1, 0))
            let barWidth = max(minBarWidth, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(color(for: i, total: barCount))
                        .frame(width: barWidth, height: height(for: i, total: geo.size.height, count: barCount))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Largest bar count that still fits inside `width` when every bar is at
    /// its minimum size. Capped at `preferredBarCount`; floored at 1.
    private func effectiveBarCount(for width: CGFloat) -> Int {
        let perBar = minBarWidth + barSpacing
        guard perBar > 0 else { return preferredBarCount }
        // (width + spacing) / perBar = how many (bar+spacing) units fit, since
        // there's no trailing spacing after the last bar.
        let fits = Int((width + barSpacing) / perBar)
        return max(1, min(preferredBarCount, fits))
    }

    private var minBarWidth: CGFloat {
        switch style {
        case .playback: return 1
        case .staticAccent, .liveInput: return 1.5
        }
    }

    private func color(for index: Int, total: Int) -> Color {
        switch style {
        case .playback(let progress, let isSentByMe):
            let fraction = Double(index) / Double(max(total - 1, 1))
            let played = progress > 0 && fraction <= progress
            if played {
                return isSentByMe ? Color.CT.outMsgText.opacity(0.95) : Color.CT.accent
            }
            return isSentByMe ? Color.CT.outMsgText.opacity(0.35) : Color.CT.textDim.opacity(0.45)
        case .staticAccent(let opacity):
            return Color.CT.accent.opacity(opacity)
        case .liveInput:
            return Color.CT.accent.opacity(liveOpacity(for: index, total: total))
        }
    }

    private func height(for index: Int, total: CGFloat, count: Int) -> CGFloat {
        switch style {
        case .playback:
            let values = downsample(samples, to: count, empty: 0.3, pad: 0.1)
            return max(2, CGFloat(values[index]) * total)
        case .staticAccent:
            let values = downsample(samples, to: count, empty: 0.3, pad: 0.1)
            return max(5, CGFloat(values[index]) * total * 0.85)
        case .liveInput:
            let sampleCount = samples.count
            guard sampleCount > 0 else { return 4 }
            let si = max(0, sampleCount - count + index)
            guard si < sampleCount else { return 4 }
            return max(4, CGFloat(samples[si]) * total * 0.9)
        }
    }

    private func liveOpacity(for index: Int, total: Int) -> Double {
        let startFilled = total - samples.count
        return index >= startFilled ? 1.0 : 0.25
    }

    private func downsample(_ array: [Float], to count: Int, empty: Float, pad: Float) -> [Float] {
        guard !array.isEmpty else { return Array(repeating: empty, count: count) }
        guard array.count >= count else {
            return array + Array(repeating: pad, count: count - array.count)
        }

        let step = Float(array.count) / Float(count)
        return (0..<count).map { i in
            let start = Int(Float(i) * step)
            let end = min(Int(Float(i + 1) * step), array.count)
            guard start < end else { return pad }
            let slice = array[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

enum VoiceUIDurationFormatter {
    static func string(_ duration: TimeInterval) -> String {
        let s = Int(duration)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
