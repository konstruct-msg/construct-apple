//
//  SpamWarningView.swift
//  Construct Messenger
//
//  Inline and full-screen UI components shown when the anti-spam layer
//  detects suspicious sending behaviour.
//

import SwiftUI

// MARK: - SpamSendState

/// Observable state for anti-spam send UI, owned by ChatViewModel.
@Observable
final class SpamSendState {
    /// Whether a delayed / warned send is currently in progress.
    var isActive: Bool = false
    /// Current progress 0…1 (drives the progress bar).
    var progress: Float = 0.0
    /// Remaining seconds in the delay.
    var remainingSeconds: Int = 0
    /// UI level: 0=none, 4–6=subtle, 8–10=visible warning, 12=full-screen.
    var level: Int = 0
    /// Show the strong-warning sheet (level ≥ 12).
    var showStrongSheet: Bool = false
    /// Whether the user pressed "Force send" (only for level 12).
    var forceSendRequested: Bool = false
}

// MARK: - Subtle progress bar (levels 4–8)

/// A thin progress bar that appears at the bottom of the input area.
/// Shown for `SpamSendState.level` 4–8 while the delay runs.
struct SpamProgressBar: View {
    let state: SpamSendState

    var body: some View {
        if state.isActive && state.level < 10 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.secondary.opacity(0.15)
                    Color.accentColor.opacity(0.7)
                        .frame(width: geo.size.width * CGFloat(state.progress))
                }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.25), value: state.progress)
            .transition(.opacity)
        }
    }
}

// MARK: - Visible warning banner (levels 8–10)

/// A compact banner shown above the text input for level 8–10 delays.
struct SpamWarningBanner: View {
    let state: SpamSendState

    var body: some View {
        if state.isActive && state.level >= 8 && state.level < 12 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(CTFont.regular(14))
                    .foregroundStyle(.orange)
                    .lineLimit(1).fixedSize()

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("spam_warning_title"))
                        .font(CTFont.bold(12))
                        .foregroundStyle(Color.CT.text)
                    Text(String(format: NSLocalizedString("spam_warning_wait", comment: ""), state.remainingSeconds))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                }

                Spacer()

                Text("\(Int(state.progress * 100))%")
                    .font(CTFont.medium(12))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.CT.bgMsg)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Strong warning sheet (level 12)

/// Full sheet presented for level-12 delays.
/// Shows a countdown, description, and a "Force send" escape hatch.
struct SpamStrongWarningSheet: View {
    @Bindable var state: SpamSendState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(CTFont.regular(48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(LocalizedStringKey("spam_strong_warning_title"))
                    .font(CTFont.bold(16))
                    .foregroundStyle(Color.CT.text)
                Text(LocalizedStringKey("spam_strong_warning_body"))
                    .font(CTFont.regular(13))
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Countdown
            VStack(spacing: 4) {
                Text("\(state.remainingSeconds)")
                    .font(CTFont.bold(40))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
                Text(LocalizedStringKey("spam_seconds"))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
            }
            .frame(width: 96, height: 96)
            .background(Color.CT.bgMsg)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.4), lineWidth: 1))

            Spacer()

            if !LocalRateLimiter.shared.isForceSendBanned {
                Button {
                    LocalRateLimiter.shared.recordForceSend()
                    state.forceSendRequested = true
                    state.showStrongSheet = false
                } label: {
                    Text(LocalizedStringKey("spam_force_send"))
                        .font(CTFont.regular(13))
                        .foregroundStyle(Color.CT.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.CT.bgMsg)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.CT.danger.opacity(0.4), lineWidth: 1))
                }
                .padding(.horizontal, 32)
            } else {
                Text(String(format: NSLocalizedString("spam_force_banned", comment: ""),
                            Int(LocalRateLimiter.shared.forceSendBanTimeRemaining / 60)))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(LocalizedStringKey("cancel")) {
                state.showStrongSheet = false
            }
            .font(CTFont.regular(13))
            .foregroundStyle(Color.CT.textDim)
            .padding(.bottom, 24)
        }
        .background(Color.CT.bg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Localization keys (add to Localizable.strings)
//
//  spam_warning_title          = "Sending…"
//  spam_warning_wait           = "Please wait %d seconds"
//  spam_strong_warning_title   = "Unusual activity"
//  spam_strong_warning_body    = "You're sending messages faster than usual. Please wait a moment."
//  spam_seconds                = "sec"
//  spam_force_send             = "I understand the risks, send anyway"
//  spam_force_banned           = "Force send disabled for %d min"
