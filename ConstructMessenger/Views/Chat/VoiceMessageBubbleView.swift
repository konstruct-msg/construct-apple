//
//  VoiceMessageBubbleView.swift
//  Construct Messenger
//
//  Playback UI for voice messages — ConstructTheme terminal style.
//  Layout: [▶/⏸]  [waveform bars]  [0:47]
//

import SwiftUI

struct VoiceMessageBubbleView: View {

    let voiceContent: VoiceMessageContent
    let isSentByMe: Bool
    let deliveryStatus: DeliveryStatus
    let onRetry: (() -> Void)?

    @StateObject private var player = AudioPlayerService.shared

    @State private var audioData: Data? = nil
    @State private var isLoading = false
    @State private var loadError = false

    private var isPlaying: Bool { player.isPlaying(voiceContent.mediaId) }
    private var isUploading: Bool { deliveryStatus == .sending && voiceContent.mediaUrl.isEmpty }
    private var uploadFailed: Bool { deliveryStatus == .failed && voiceContent.mediaUrl.isEmpty }
    private var isMediaUnavailable: Bool {
        voiceContent.mediaId.isEmpty || voiceContent.mediaKey.isEmpty
    }

    var body: some View {
        Group {
            if isUploading {
                uploadingBody
            } else if uploadFailed {
                failedBody
            } else if isMediaUnavailable {
                unavailableBody
            } else {
                playerBody
            }
        }
        .onDisappear {
            if isPlaying { player.stop() }
        }
        .onChange(of: ConnectionStatusManager.shared.connectionStatus) { _, newStatus in
            // Auto-retry download when connection restores after a transient failure.
            if newStatus == .connected && loadError && audioData == nil {
                loadError = false
                loadAndPlay()
            }
        }
    }

    // MARK: - Player (normal state)

    private var playerBody: some View {
        HStack(spacing: 8) {
            Button {
                if let data = audioData {
                    player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                } else if !isLoading {
                    loadAndPlay()
                }
            } label: {
                if isLoading {
                    Text("[···]")
                        .font(CTFont.regular(13))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(isSentByMe ? .white : Color.CT.accent)
                        .frame(minWidth: 38)
                } else {
                    Text(isPlaying ? "[||]" : "[>]")
                        .font(CTFont.regular(13))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(isSentByMe ? .white : Color.CT.accent)
                        .frame(minWidth: 38)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            CTWaveformView(
                samples: voiceContent.waveform,
                progress: isPlaying ? player.progress : 0,
                isSentByMe: isSentByMe
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)

            Text(durationLabel)
                .font(CTFont.regular(11))
                .foregroundColor(isSentByMe ? Color.white.opacity(0.85) : Color.CT.textDim)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe))
        .ctNoiseBorder()
    }

    // MARK: - Uploading state

    private var uploadingBody: some View {
        HStack(spacing: 8) {
            Text("[···]")
                .font(CTFont.regular(13))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(isSentByMe ? .white : Color.CT.textDim)
                .frame(minWidth: 38)

            CTWaveformView(
                samples: voiceContent.waveform,
                progress: 0,
                isSentByMe: isSentByMe
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .opacity(0.4)

            Text(durationLabel)
                .font(CTFont.regular(11))
                .foregroundColor(isSentByMe ? Color.white.opacity(0.7) : Color.CT.textDim)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.7))
        .ctNoiseBorder()
    }

    // MARK: - Failed state

    private var failedBody: some View {
        HStack(spacing: 8) {
            Button { onRetry?() } label: {
                Text("[↺]")
                    .font(CTFont.regular(13))
                    .foregroundColor(Color(hex: 0xE05555))
                    .frame(width: 38)
            }
            .buttonStyle(.plain)

            CTWaveformView(
                samples: voiceContent.waveform,
                progress: 0,
                isSentByMe: isSentByMe
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .opacity(0.35)

            Text(durationLabel)
                .font(CTFont.regular(11))
                .foregroundColor(Color(hex: 0xE05555).opacity(0.8))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.CT.bgMsg)
        .overlay(
            Rectangle()
                .stroke(Color(hex: 0xE05555).opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Unavailable state

    private var unavailableBody: some View {
        HStack(spacing: 8) {
            Text("[—]")
                .font(CTFont.regular(13))
                .foregroundColor(Color.CT.textDim)
                .frame(width: 38)

            CTWaveformView(
                samples: voiceContent.waveform,
                progress: 0,
                isSentByMe: isSentByMe
            )
            .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
            .opacity(0.2)

            Text(durationLabel)
                .font(CTFont.regular(11))
                .foregroundColor(Color.CT.textDim)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.35))
        .ctNoiseBorder()
    }

    // MARK: - Duration

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

// MARK: - CT Waveform (terminal: flat Rectangle bars)

private struct CTWaveformView: View {
    let samples: [Float]
    let progress: Double
    let isSentByMe: Bool

    private let barCount = 40
    private let barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let totalSpacing = barSpacing * CGFloat(barCount - 1)
            let barWidth = max(1, (geo.size.width - totalSpacing) / CGFloat(barCount))
            let downsampled = downsample(samples, to: barCount)

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    let fraction = Double(i) / Double(max(barCount - 1, 1))
                    let played = progress > 0 && fraction <= progress
                    let height = max(2, CGFloat(downsampled[i]) * geo.size.height)

                    Rectangle()
                        .fill(played ? playedColor : unplayedColor)
                        .frame(width: barWidth, height: height)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private var playedColor: Color {
        isSentByMe ? Color.white.opacity(0.95) : Color.CT.accent
    }
    private var unplayedColor: Color {
        isSentByMe ? Color.white.opacity(0.35) : Color.CT.textDim.opacity(0.45)
    }

    private func downsample(_ array: [Float], to count: Int) -> [Float] {
        guard !array.isEmpty else { return Array(repeating: 0.3, count: count) }
        guard array.count >= count else {
            return array + Array(repeating: 0.1, count: count - array.count)
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
    VStack(spacing: 8) {
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "t1", mediaUrl: "x", mediaKey: "k", mediaType: "audio/m4a", size: 120_000, duration: 47, waveform: (0..<100).map { _ in Float.random(in: 0.1...1.0) }, hash: ""),
            isSentByMe: true, deliveryStatus: .delivered, onRetry: nil
        )
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "t2", mediaUrl: "x", mediaKey: "k", mediaType: "audio/m4a", size: 80_000, duration: 22, waveform: (0..<100).map { _ in Float.random(in: 0.05...0.8) }, hash: ""),
            isSentByMe: false, deliveryStatus: .delivered, onRetry: nil
        )
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "", mediaUrl: "", mediaKey: "", mediaType: "audio/m4a", size: 0, duration: 8, waveform: (0..<100).map { _ in Float.random(in: 0.1...0.9) }, hash: ""),
            isSentByMe: true, deliveryStatus: .failed, onRetry: { }
        )
    }
    .padding()
    .background(Color.CT.bg)
}
