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
    var transcript: String? = nil
    var isTranscribing: Bool = false
    var onTranscribe: (() -> Void)? = nil

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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    if let data = audioData {
                        player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                    } else if !isLoading {
                        loadAndPlay()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(isSentByMe ? .white : Color.CT.accent)
                            .frame(minWidth: 38)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundColor(isSentByMe ? .white : Color.CT.accent)
                            .frame(minWidth: 38)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                VoiceWaveformView(
                    samples: voiceContent.waveform,
                    style: .playback(progress: isPlaying ? player.progress : 0, isSentByMe: isSentByMe)
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

            transcriptSection
        }
        .frame(maxWidth: 360)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.CT.noise, lineWidth: 0.5))
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let text = transcript, !text.isEmpty {
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            Text(text)
                .font(CTFont.regular(12))
                .foregroundColor(isSentByMe ? .white.opacity(0.85) : Color.CT.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        } else if let onTranscribe, VoiceTranscriptionService.shared.isAvailable {
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            Button(action: onTranscribe) {
                HStack(spacing: 4) {
                    if isTranscribing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.5)
                            .tint(isSentByMe ? .white : Color.CT.accent)
                    } else {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 11))
                    }
                    Text(isTranscribing
                         ? NSLocalizedString("stt_transcribing", comment: "")
                         : NSLocalizedString("stt_transcribe_button", comment: ""))
                        .font(CTFont.regular(11))
                }
                .foregroundColor(isSentByMe ? .white.opacity(0.65) : Color.CT.textDim)
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Uploading state

    private var uploadingBody: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(isSentByMe ? .white : Color.CT.textDim)
                .frame(minWidth: 38)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
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
        .frame(maxWidth: 360)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.CT.noise, lineWidth: 0.5))
    }

    // MARK: - Failed state

    private var failedBody: some View {
        HStack(spacing: 8) {
            Button { onRetry?() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(hex: 0xE05555))
                    .frame(width: 38)
            }
            .buttonStyle(.plain)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
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
        .frame(maxWidth: 360)
        .background(Color.CT.bgMsg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: 0xE05555).opacity(0.5), lineWidth: 1))
    }

    // MARK: - Unavailable state

    private var unavailableBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(Color.CT.textDim)
                .frame(width: 38)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
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
        .frame(maxWidth: 360)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.CT.noise, lineWidth: 0.5))
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
        return VoiceUIDurationFormatter.string(seconds)
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
                    mediaKey: voiceContent.mediaKey
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
                    Log.error("Voice download failed: \(error.localizedDescription)", category: "VoiceMessageBubbleView")
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "t1", mediaUrl: "x", mediaKey: Data(), mediaType: "audio/m4a", size: 120_000, duration: 47, waveform: (0..<100).map { _ in Float.random(in: 0.1...1.0) }, hash: ""),
            isSentByMe: true, deliveryStatus: .delivered, onRetry: nil
        )
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "t2", mediaUrl: "x", mediaKey: Data(), mediaType: "audio/m4a", size: 80_000, duration: 22, waveform: (0..<100).map { _ in Float.random(in: 0.05...0.8) }, hash: ""),
            isSentByMe: false, deliveryStatus: .delivered, onRetry: nil
        )
        VoiceMessageBubbleView(
            voiceContent: VoiceMessageContent(type: "voice", mediaId: "", mediaUrl: "", mediaKey: Data(), mediaType: "audio/m4a", size: 0, duration: 8, waveform: (0..<100).map { _ in Float.random(in: 0.1...0.9) }, hash: ""),
            isSentByMe: true, deliveryStatus: .failed, onRetry: { }
        )
    }
    .padding()
    .background(Color.CT.bg)
}
