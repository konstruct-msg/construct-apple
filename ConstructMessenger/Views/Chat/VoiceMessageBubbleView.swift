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
    /// Where a finger is on the waveform while it drags; the seek lands when it lifts.
    @State private var scrubFraction: Double? = nil

    /// True when the transcript is actually rendered below the waveform.
    private var isTranscriptShown: Bool { (transcript?.isEmpty == false) && isTranscriptExpanded }

    private var isPlaying: Bool { player.isPlaying(voiceContent.mediaId) }
    /// Playing or paused: the position and the time left are this track's.
    private var isActive: Bool { player.isActive(voiceContent.mediaId) }
    private var shownProgress: Double { scrubFraction ?? (isActive ? player.progress : 0) }
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
            if isActive { player.stop() }
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
                    if isActive {
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
                            .font(CTIcon.font(CTIcon.row, weight: .regular))
                            .foregroundColor(isSentByMe ? Color.CT.outMsgText : Color.CT.accent)
                            .frame(minWidth: ChatUIConstants.Voice.controlWidth)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)

                VoiceWaveformView(
                    samples: voiceContent.waveform,
                    style: .playback(progress: shownProgress, isSentByMe: isSentByMe)
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: ChatUIConstants.Voice.waveformHeight,
                    maxHeight: ChatUIConstants.Voice.waveformHeight
                )
                .overlay { scrubSurface }

                if isActive { rateButton }

                transcribeToggle

                Text(durationLabel)
                    .font(CTFont.ui(ChatUIConstants.Typography.durationSize))
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

    /// Tap a point of the waveform to play from there; drag along it to move through the track.
    /// The drag takes only a sideways movement, so a vertical one is still the list's scroll, and
    /// it sits on the waveform — a child of the bubble — so it wins over the bubble's reply swipe.
    private var scrubSurface: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in
                    seek(to: VoiceScrub.fraction(at: location.x, width: geo.size.width))
                }
                .gesture(
                    DragGesture(minimumDistance: ChatUIConstants.Voice.scrubMinimumDistance)
                        .onChanged { value in
                            guard scrubFraction != nil
                                || abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            scrubFraction = VoiceScrub.fraction(at: value.location.x, width: geo.size.width)
                        }
                        .onEnded { _ in
                            if let fraction = scrubFraction { seek(to: fraction) }
                            scrubFraction = nil
                        }
                )
        }
    }

    private func seek(to fraction: Double) {
        let id = voiceContent.mediaId
        if isActive {
            player.seek(mediaId: id, data: Data(), to: fraction)
        } else if let data = audioData {
            player.seek(mediaId: id, data: data, to: fraction)
        } else if !isLoading {
            loadAndPlay(startingAt: fraction)
        }
    }

    /// 1× → 1.25× → 1.5× → 2×, kept for every voice message after this one.
    private var rateButton: some View {
        Button { player.cycleRate() } label: {
            Text(VoiceScrub.rateLabel(player.rate))
                .font(CTFont.ui(ChatUIConstants.Typography.durationSize, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(isSentByMe ? Color.CT.outMsgText : Color.CT.accent)
                .frame(minWidth: ChatUIConstants.Voice.toggleSize, minHeight: ChatUIConstants.Voice.toggleSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("voice_playback_speed", comment: ""))
        .accessibilityValue(VoiceScrub.rateLabel(player.rate))
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
                        .font(CTIcon.font(CTIcon.caption, weight: .regular))
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
                .font(CTFont.ui(ChatUIConstants.Typography.transcriptSize))
                .foregroundColor(isSentByMe ? Color.CT.outMsgText.opacity(0.85) : Color.CT.textDim)
                // The transcript arrives after its row was measured, and the eager transcript
                // stack is laid out in that old height for at least a pass; a stack short of
                // height compresses its most compressible `Text` — this one, to "…" after a few
                // words. The message text carries the same modifier for the same reason.
                .fixedSize(horizontal: false, vertical: true)
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
                .font(CTFont.ui(ChatUIConstants.Typography.durationSize))
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
                    .font(CTIcon.font(CTIcon.row, weight: .regular))
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
                .font(CTFont.ui(ChatUIConstants.Typography.durationSize))
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
                .font(CTIcon.font(CTIcon.row, weight: .regular))
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
                .font(CTFont.ui(ChatUIConstants.Typography.durationSize))
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
        if isActive || scrubFraction != nil {
            let total = player.totalDuration > 0 && isActive ? player.totalDuration : voiceContent.duration
            seconds = total * (1 - shownProgress)
        } else {
            seconds = voiceContent.duration
        }
        return VoiceUIDurationFormatter.string(seconds)
    }

    // MARK: - Download

    private func loadAndPlay(startingAt fraction: Double? = nil) {
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
                    if let fraction {
                        player.seek(mediaId: voiceContent.mediaId, data: data, to: fraction)
                    } else {
                        player.togglePlay(mediaId: voiceContent.mediaId, data: data)
                    }
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

// MARK: - Scrubbing and speed

/// The waveform's arithmetic, apart from the view so a test can reach it.
enum VoiceScrub {
    /// The point of the track under `x` on a waveform `width` wide, 0…1.
    static func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, x.isFinite else { return 0 }
        return Double(min(max(x / width, 0), 1))
    }

    /// "1×", "1.25×", "1.5×", "2×".
    static func rateLabel(_ rate: Float) -> String {
        let number = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return number + "×"
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
