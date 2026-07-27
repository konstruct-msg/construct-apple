//
//  VoiceInputBars.swift
//  Construct Messenger
//
//  Full-width accent-pill bars shown instead of the text input while the user
//  is recording or reviewing a voice message before sending.
//  iOS only — macOS doesn't support voice messages via AVAudioRecorder.
//

import SwiftUI
import Combine


// MARK: - Recording Bar

struct VoiceRecordingBar: View {
    let duration: TimeInterval
    let waveform: [Float]
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: ChatUIConstants.InputBar.voiceChromeIconSize))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)
            .padding(.leading, CTLayout.edgePad)

            // Live waveform
            VoiceWaveformView(samples: waveform, style: .liveInput)
                .frame(maxWidth: .infinity)
                .frame(height: ChatUIConstants.Voice.waveformHeight)
                .padding(.horizontal, CTLayout.edgePad)

            // Timer
            timerLabel(duration)

            // Stop
            Button(action: onStop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: ChatUIConstants.InputBar.voiceChromeIconSize))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
            .padding(.leading, CTLayout.chromeGap)
            .padding(.trailing, CTLayout.edgePad)
        }
        .ctBar
    }
}

// MARK: - Preview Bar

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
                    .font(.system(size: ChatUIConstants.InputBar.voiceChromeIconSize))
                    .foregroundStyle(Color.CT.danger)
            }
            .buttonStyle(.plain)
            .padding(.leading, CTLayout.edgePad)

            // Static waveform
            VoiceWaveformView(samples: waveform, style: .staticAccent())
                .frame(maxWidth: .infinity)
                .frame(height: ChatUIConstants.Voice.waveformHeight)
                .padding(.horizontal, CTLayout.edgePad)

            // Duration
            timerLabel(duration)

            // Send
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: CTLayout.callIconSize))
                    .foregroundStyle(Color.CT.accent)
            }
            .buttonStyle(.plain)
            .padding(.leading, CTLayout.chromeGap)
            .padding(.trailing, CTLayout.edgePad)
        }
        .ctBar
    }
}

// MARK: - Shared helpers

private func timerLabel(_ duration: TimeInterval) -> some View {
    return Text(VoiceUIDurationFormatter.string(duration))
        .font(CTFont.medium(14))
        .foregroundStyle(Color.CT.textDim)
        .frame(minWidth: 42, alignment: .trailing)
}

private extension View {
    var ctBar: some View {
        self
            .frame(height: ChatUIConstants.InputBar.voiceChromeHeight)
            .background(Color.CT.outMsgBg)
            .clipShape(CTShape.pill())
            .overlay(CTShape.pill().strokeBorder(Color.CT.accent.opacity(0.25), lineWidth: 1))
            .padding(.horizontal, CTLayout.inlinePad)
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

