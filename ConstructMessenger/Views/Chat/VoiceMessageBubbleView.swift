//
//  VoiceMessageBubbleView.swift
//  Construct Messenger
//
//  Playback UI for voice messages — ConstructTheme terminal style.
//  Layout: [▶/⏸]  [waveform bars]  [0:47]
//

import SwiftUI
import Combine

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
    /// Controls whether the transcript text is visible below the waveform.
    /// Defaults to true and is flipped to true again whenever a new transcript
    /// arrives — so a freshly-completed transcription reveals itself, but the
    /// user can still collapse it via the inline toggle.
    @State private var isTranscriptExpanded: Bool = true

    /// True when the transcript is actually rendered below the waveform.
    private var isTranscriptShown: Bool { (transcript?.isEmpty == false) && isTranscriptExpanded }

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
            HStack(spacing: ChatUIConstants.Voice.playerSpacing) {
                Button {
                    if isPlaying {
                        // Active track — may have been started by continuous playback, so this
                        // view's `audioData` can be nil. togglePlay ignores `data` for the
                        // active track, so pause/resume works without re-downloading.
                        player.togglePlay(mediaId: voiceContent.mediaId, data: audioData ?? Data())
                    } else if let data = audioData {
                        player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                    } else if !isLoading {
                        loadAndPlay()
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(isSentByMe ? Color.CT.outMsgText : Color.CT.accent)
                            .frame(minWidth: ChatUIConstants.Voice.controlWidth)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: ChatUIConstants.Voice.playIconSize, weight: .regular))
                            .foregroundColor(isSentByMe ? Color.CT.outMsgText : Color.CT.accent)
                            .frame(minWidth: ChatUIConstants.Voice.controlWidth)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                VoiceWaveformView(
                    samples: voiceContent.waveform,
                    style: .playback(progress: isPlaying ? player.progress : 0, isSentByMe: isSentByMe)
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: ChatUIConstants.Voice.waveformHeight,
                    maxHeight: ChatUIConstants.Voice.waveformHeight
                )

                transcribeToggle

                Text(durationLabel)
                    .font(CTFont.regular(ChatUIConstants.Typography.durationSize))
                    .foregroundColor(isSentByMe ? Color.CT.outMsgText.opacity(0.85) : Color.CT.textDim)
                    .monospacedDigit()
                    .frame(width: ChatUIConstants.Voice.durationWidth, alignment: .trailing)
            }
            .padding(.horizontal, ChatUIConstants.Voice.horizontalPadding)
            .padding(.vertical, ChatUIConstants.Voice.verticalPadding)

            transcriptSection
        }
        .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe))
        .clipShape(ChatUIConstants.Voice.shape)
        .overlay(ChatUIConstants.Voice.shape.stroke(Color.CT.noise, lineWidth: ChatUIConstants.Voice.strokeWidth))
        .animation(.easeInOut(duration: 0.2), value: isTranscriptShown)
        .onChange(of: transcript) { _, newTranscript in
            // Auto-reveal a fresh transcript so the user sees what they
            // triggered. They can still collapse via the inline toggle.
            if let newTranscript, !newTranscript.isEmpty {
                isTranscriptExpanded = true
            }
        }
    }

    /// Inline compact toggle that lives in the player HStack between the
    /// waveform and the duration label. Three states:
    ///   1. no transcript yet, idle  → `textformat` icon, tap → onTranscribe()
    ///   2. transcribing             → spinner replaces the icon
    ///   3. transcript exists        → tap toggles `isTranscriptExpanded`;
    ///                                 icon is accent when expanded, dim when collapsed
    @ViewBuilder
    private var transcribeToggle: some View {
        let hasTranscript = (transcript?.isEmpty == false)
        let isInteractive = hasTranscript || (onTranscribe != nil && VoiceTranscriptionService.shared.isAvailable)
        if isInteractive {
            Button {
                if hasTranscript {
                    isTranscriptExpanded.toggle()
                } else {
                    onTranscribe?()
                }
            } label: {
                if isTranscribing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(isSentByMe ? Color.CT.outMsgText : Color.CT.accent)
                        .frame(width: ChatUIConstants.Voice.toggleSize, height: ChatUIConstants.Voice.toggleSize)
                } else {
                    Image(systemName: "textformat")
                        .font(.system(size: ChatUIConstants.Voice.toggleIconSize, weight: .regular))
                        .foregroundColor(toggleTint(hasTranscript: hasTranscript))
                        .frame(width: ChatUIConstants.Voice.toggleSize, height: ChatUIConstants.Voice.toggleSize)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            .accessibilityLabel(NSLocalizedString(
                hasTranscript
                    ? (isTranscriptExpanded ? "stt_hide_transcript" : "stt_show_transcript")
                    : "stt_transcribe_button",
                comment: ""
            ))
        }
    }

    /// Active (accent) when the transcript exists and is currently shown;
    /// dim otherwise. Mirrors play-button colour rules for the "sent by me"
    /// branch (white tint vs textDim).
    private func toggleTint(hasTranscript: Bool) -> Color {
        if hasTranscript && isTranscriptExpanded {
            return isSentByMe ? Color.CT.outMsgText : Color.CT.accent
        } else {
            return isSentByMe ? Color.CT.outMsgText.opacity(0.55) : Color.CT.textDim
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        if let text = transcript, !text.isEmpty, isTranscriptExpanded {
            Rectangle().fill(Color.CT.noise).frame(height: 1)
            Text(text)
                .font(CTFont.regular(ChatUIConstants.Typography.transcriptSize))
                .foregroundColor(isSentByMe ? Color.CT.outMsgText.opacity(0.85) : Color.CT.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ChatUIConstants.Voice.horizontalPadding)
                .padding(.vertical, ChatUIConstants.Voice.verticalPadding)
        }
    }

    // MARK: - Uploading state

    private var uploadingBody: some View {
        HStack(spacing: ChatUIConstants.Voice.playerSpacing) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(isSentByMe ? Color.CT.outMsgText : Color.CT.textDim)
                .frame(minWidth: ChatUIConstants.Voice.controlWidth)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: ChatUIConstants.Voice.waveformHeight,
                maxHeight: ChatUIConstants.Voice.waveformHeight
            )
            .opacity(0.4)

            Text(durationLabel)
                .font(CTFont.regular(ChatUIConstants.Typography.durationSize))
                .foregroundColor(isSentByMe ? Color.CT.outMsgText.opacity(0.7) : Color.CT.textDim)
                .monospacedDigit()
                .frame(width: ChatUIConstants.Voice.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, ChatUIConstants.Voice.horizontalPadding)
        .padding(.vertical, ChatUIConstants.Voice.verticalPadding)
        .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.7))
        .clipShape(ChatUIConstants.Voice.shape)
        .overlay(ChatUIConstants.Voice.shape.stroke(Color.CT.noise, lineWidth: ChatUIConstants.Voice.strokeWidth))
    }

    // MARK: - Failed state

    private var failedBody: some View {
        HStack(spacing: ChatUIConstants.Voice.playerSpacing) {
            Button { onRetry?() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: ChatUIConstants.Voice.playIconSize, weight: .regular))
                    .foregroundColor(Color(hex: 0xE05555))
                    .frame(width: ChatUIConstants.Voice.controlWidth)
            }
            .buttonStyle(.plain)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: ChatUIConstants.Voice.waveformHeight,
                maxHeight: ChatUIConstants.Voice.waveformHeight
            )
            .opacity(0.35)

            Text(durationLabel)
                .font(CTFont.regular(ChatUIConstants.Typography.durationSize))
                .foregroundColor(Color(hex: 0xE05555).opacity(0.8))
                .monospacedDigit()
                .frame(width: ChatUIConstants.Voice.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, ChatUIConstants.Voice.horizontalPadding)
        .padding(.vertical, ChatUIConstants.Voice.verticalPadding)
        .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
        .background(Color.CT.bgMsg)
        .clipShape(ChatUIConstants.Voice.shape)
        .overlay(ChatUIConstants.Voice.shape.stroke(Color(hex: 0xE05555).opacity(0.5), lineWidth: 1))
    }

    // MARK: - Unavailable state

    private var unavailableBody: some View {
        HStack(spacing: ChatUIConstants.Voice.playerSpacing) {
            Image(systemName: "waveform.slash")
                .font(.system(size: ChatUIConstants.Voice.playIconSize, weight: .regular))
                .foregroundColor(Color.CT.textDim)
                .frame(width: ChatUIConstants.Voice.controlWidth)

            VoiceWaveformView(
                samples: voiceContent.waveform,
                style: .playback(progress: 0, isSentByMe: isSentByMe)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: ChatUIConstants.Voice.waveformHeight,
                maxHeight: ChatUIConstants.Voice.waveformHeight
            )
            .opacity(0.2)

            Text(durationLabel)
                .font(CTFont.regular(ChatUIConstants.Typography.durationSize))
                .foregroundColor(Color.CT.textDim)
                .monospacedDigit()
                .frame(width: ChatUIConstants.Voice.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, ChatUIConstants.Voice.horizontalPadding)
        .padding(.vertical, ChatUIConstants.Voice.verticalPadding)
        .frame(maxWidth: ChatUIConstants.Bubble.maxWidth)
        .background(CTMessageBubbleTheme.background(isSentByMe: isSentByMe).opacity(0.35))
        .clipShape(ChatUIConstants.Voice.shape)
        .overlay(ChatUIConstants.Voice.shape.stroke(Color.CT.noise, lineWidth: ChatUIConstants.Voice.strokeWidth))
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
    VStack(spacing: ChatUIConstants.Shell.listSpacing) {
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
