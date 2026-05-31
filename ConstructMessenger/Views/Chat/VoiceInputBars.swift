//
//  VoiceInputBars.swift
//  Construct Messenger
//
//  Full-width accent-pill bars shown instead of the text input while the user
//  is recording or reviewing a voice message before sending.
//  iOS only — macOS doesn't support voice messages via AVAudioRecorder.
//

import SwiftUI

#if os(iOS)

// MARK: - Recording Bar

/// Shown while the microphone is active.
struct VoiceRecordingBar: View {
    let duration: TimeInterval
    let waveform: [Float]
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onCancel) {
                Image(systemName: "x.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)

            // Live waveform
            LiveWaveformView(samples: waveform)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .padding(.horizontal, 12)

            // Timer
            timerLabel(duration)

            // Stop
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.trailing, 12)
        }
        .ctBar
    }
}

// MARK: - Preview Bar

/// Shown after recording stops — lets the user review before sending.
/// Layout: [del]  [static waveform]  [0:47]  [→]
struct VoicePreviewBar: View {
    let duration: TimeInterval
    let waveform: [Float]
    let onSend: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Discard
            Button(action: onDiscard) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)

            // Static waveform
            StaticWaveformView(samples: waveform)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .padding(.horizontal, 12)

            // Duration
            timerLabel(duration)

            // Send
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.trailing, 12)
        }
        .ctBar
    }
}

// MARK: - Shared helpers

private func timerLabel(_ duration: TimeInterval) -> some View {
    let s = Int(duration)
    return Text(String(format: "%d:%02d", s / 60, s % 60))
        .font(CTFont.medium(14))
        .foregroundStyle(Color.CT.textDim)
        .frame(minWidth: 42, alignment: .trailing)
}

private extension View {
    var ctBar: some View {
        self
            .frame(height: 52)
            .background(Color.CT.outMsgBg)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.CT.accent.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, 8)
    }
}

// MARK: - Live Waveform (recording)
// Bars fill from the left as the buffer grows; each bar shows the latest samples.

struct LiveWaveformView: View {
    let samples: [Float]

    private let barCount = 52
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Rectangle()
                        .fill(Color.CT.accent.opacity(opacity(for: i)))
                        .frame(width: barWidth, height: height(for: i, total: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func height(for index: Int, total: CGFloat) -> CGFloat {
        let count = samples.count
        guard count > 0 else { return 4 }
        let si = max(0, count - barCount + index)
        guard si < count else { return 4 }
        return max(4, CGFloat(samples[si]) * total * 0.9)
    }

    private func opacity(for index: Int) -> Double {
        let startFilled = barCount - samples.count
        return index >= startFilled ? 1.0 : 0.25
    }
}

// MARK: - Static Waveform (preview)

struct StaticWaveformView: View {
    let samples: [Float]

    private let barCount   = 36
    private let barSpacing: CGFloat = 2.5

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1.5, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    Rectangle()
                        .fill(Color.CT.accent.opacity(0.70))
                        .frame(width: barWidth, height: height(for: i, total: geo.size.height))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func height(for index: Int, total: CGFloat) -> CGFloat {
        guard !samples.isEmpty else { return 5 }
        let step = Float(samples.count) / Float(barCount)
        let si   = Int(Float(index) * step)
        let ei   = min(Int(Float(index + 1) * step), samples.count)
        guard si < ei else { return 5 }
        let avg = samples[si..<ei].reduce(0, +) / Float(ei - si)
        return max(5, CGFloat(avg) * total * 0.85)
    }
}

// MARK: - Previews

#Preview("Recording bar") {
    VStack {
        Spacer()
        VoiceRecordingBar(
            duration: 12,
            waveform: (0..<30).map { _ in Float.random(in: 0.1...1.0) },
            onStop: {},
            onCancel: {}
        )
        Spacer()
    }
    .background(Color.CT.bg)
    .preferredColorScheme(.dark)
}

#Preview("Preview bar") {
    VStack {
        Spacer()
        VoicePreviewBar(
            duration: 47,
            waveform: (0..<100).map { _ in Float.random(in: 0.05...0.9) },
            onSend: {},
            onDiscard: {}
        )
        Spacer()
    }
    .background(Color.CT.bg)
    .preferredColorScheme(.dark)
}

#endif
