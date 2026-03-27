//
//  VoiceMessageBubbleView.swift
//  Construct Messenger
//
//  Playback UI for voice messages.
//  Layout: [▶/⏸]  [waveform bars with progress overlay]  [0:47]
//

import SwiftUI

struct VoiceMessageBubbleView: View {

    let voiceContent: VoiceMessageContent
    let isSentByMe: Bool

    @StateObject private var player = AudioPlayerService.shared

    @State private var audioData: Data? = nil
    @State private var isLoading = false
    @State private var loadError = false

    private var isPlaying: Bool { player.isPlaying(voiceContent.mediaId) }

    var body: some View {
        HStack(spacing: 10) {
            // Play / Pause button
            Button {
                if let data = audioData {
                    player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                } else if !isLoading {
                    loadAndPlay()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(isSentByMe ? Color.white.opacity(0.25) : Color.accentColor.opacity(0.15))
                        .frame(width: 36, height: 36)

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.75)
                            .tint(isSentByMe ? .white : .accentColor)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSentByMe ? .white : .accentColor)
                            .offset(x: isPlaying ? 0 : 1.5)   // optical centering for ▶
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            // Waveform + progress
            WaveformBarsView(
                samples: voiceContent.waveform,
                progress: isPlaying ? player.progress : 0,
                isSentByMe: isSentByMe
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)

            // Duration label
            Text(durationLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isSentByMe ? Color.white.opacity(0.85) : Color.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSentByMe ? Color.accentColor : Color(.systemGray5))
        )
        .onDisappear {
            if isPlaying { player.stop() }
        }
    }

    // MARK: - Duration display

    private var durationLabel: String {
        let seconds: TimeInterval
        if isPlaying {
            seconds = player.totalDuration > 0
                ? player.totalDuration * (1 - player.progress)
                : voiceContent.duration
        } else {
            seconds = voiceContent.duration
        }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Download

    private func loadAndPlay() {
        isLoading = true
        loadError  = false
        Task {
            do {
                let data = try await MediaManager.shared.downloadAndDecryptMedia(
                    mediaId: voiceContent.mediaId,
                    mediaUrl: voiceContent.mediaUrl,
                    mediaKeyBase64: voiceContent.mediaKey
                )
                await MainActor.run {
                    self.audioData = data
                    self.isLoading  = false
                    player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.loadError  = true
                    Log.error("❌ Voice download failed: \(error.localizedDescription)", category: "VoiceMessageBubbleView")
                }
            }
        }
    }
}

// MARK: - Waveform Bar Chart

private struct WaveformBarsView: View {
    let samples: [Float]
    let progress: Double       // 0.0–1.0
    let isSentByMe: Bool

    private let barCount = 40
    private let barSpacing: CGFloat = 2
    private let minBarHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(barCount))

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let fraction = Double(i) / Double(barCount - 1)
                    let played = fraction <= progress

                    Capsule()
                        .fill(played ? playedColor : unplayedColor)
                        .frame(width: barWidth, height: barHeight(for: i, totalHeight: geo.size.height))
                }
            }
        }
    }

    private var playedColor: Color {
        isSentByMe ? Color.white.opacity(0.95) : Color.accentColor
    }

    private var unplayedColor: Color {
        isSentByMe ? Color.white.opacity(0.40) : Color.secondary.opacity(0.40)
    }

    private func barHeight(for index: Int, totalHeight: CGFloat) -> CGFloat {
        guard !samples.isEmpty else { return minBarHeight }
        let downsampled = downsample(samples, to: barCount)
        let rawHeight = CGFloat(downsampled[index]) * totalHeight
        return max(minBarHeight, rawHeight)
    }

    private func downsample(_ array: [Float], to count: Int) -> [Float] {
        guard array.count >= count else {
            // Pad with zeros if fewer samples than bars
            return array + Array(repeating: 0, count: count - array.count)
        }
        let step = Float(array.count) / Float(count)
        return (0..<count).map { i in
            let start = Int(Float(i) * step)
            let end   = min(Int(Float(i + 1) * step), array.count)
            let slice = array[start..<end]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(
                type: "voice",
                mediaId: "test",
                mediaUrl: "",
                mediaKey: "",
                mediaType: "audio/m4a",
                size: 120_000,
                duration: 47,
                waveform: (0..<100).map { _ in Float.random(in: 0.1...1.0) },
                hash: ""
            ),
            isSentByMe: true
        )

        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(
                type: "voice",
                mediaId: "test2",
                mediaUrl: "",
                mediaKey: "",
                mediaType: "audio/m4a",
                size: 80_000,
                duration: 12,
                waveform: (0..<100).map { _ in Float.random(in: 0.05...0.8) },
                hash: ""
            ),
            isSentByMe: false
        )
    }
    .padding()
}
