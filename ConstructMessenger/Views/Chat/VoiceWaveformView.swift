import SwiftUI

struct VoiceWaveformView: View {
    enum Style {
        case playback(progress: Double, isSentByMe: Bool)
        case staticAccent(opacity: Double = 0.7)
        case liveInput
    }

    let samples: [Float]
    let style: Style

    private let barCount = 52
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(minBarWidth, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Rectangle()
                        .fill(color(for: i))
                        .frame(width: barWidth, height: height(for: i, total: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var minBarWidth: CGFloat {
        switch style {
        case .playback: return 1
        case .staticAccent, .liveInput: return 1.5
        }
    }

    private func color(for index: Int) -> Color {
        switch style {
        case .playback(let progress, let isSentByMe):
            let fraction = Double(index) / Double(max(barCount - 1, 1))
            let played = progress > 0 && fraction <= progress
            if played {
                return isSentByMe ? Color.white.opacity(0.95) : Color.CT.accent
            }
            return isSentByMe ? Color.white.opacity(0.35) : Color.CT.textDim.opacity(0.45)
        case .staticAccent(let opacity):
            return Color.CT.accent.opacity(opacity)
        case .liveInput:
            return Color.CT.accent.opacity(liveOpacity(for: index))
        }
    }

    private func height(for index: Int, total: CGFloat) -> CGFloat {
        switch style {
        case .playback:
            let values = downsample(samples, to: barCount, empty: 0.3, pad: 0.1)
            return max(2, CGFloat(values[index]) * total)
        case .staticAccent:
            let values = downsample(samples, to: barCount, empty: 0.3, pad: 0.1)
            return max(5, CGFloat(values[index]) * total * 0.85)
        case .liveInput:
            let count = samples.count
            guard count > 0 else { return 4 }
            let si = max(0, count - barCount + index)
            guard si < count else { return 4 }
            return max(4, CGFloat(samples[si]) * total * 0.9)
        }
    }

    private func liveOpacity(for index: Int) -> Double {
        let startFilled = barCount - samples.count
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
