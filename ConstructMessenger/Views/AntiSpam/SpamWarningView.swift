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
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("spam_warning_title"))
                        .font(.footnote.weight(.semibold))
                    Text(String(format: NSLocalizedString("spam_warning_wait", comment: ""), state.remainingSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Circular progress indicator
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: CGFloat(state.progress))
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: state.progress)
                    Text("\(Int(state.progress * 100))%")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                }
                .frame(width: 36, height: 36)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(LocalizedStringKey("spam_strong_warning_title"))
                    .font(.title3.weight(.bold))
                Text(LocalizedStringKey("spam_strong_warning_body"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Countdown + progress ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 8)
                    .frame(width: 96, height: 96)
                Circle()
                    .trim(from: 0, to: CGFloat(state.progress))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: state.progress)
                    .frame(width: 96, height: 96)
                VStack(spacing: 0) {
                    Text("\(state.remainingSeconds)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(LocalizedStringKey("spam_seconds"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Force-send escape hatch
            if !LocalRateLimiter.shared.isForceSendBanned {
                Button(role: .destructive) {
                    LocalRateLimiter.shared.recordForceSend()
                    state.forceSendRequested = true
                    state.showStrongSheet = false
                } label: {
                    Label(LocalizedStringKey("spam_force_send"), systemImage: "paperplane.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .padding(.horizontal, 32)
            } else {
                Text(String(format: NSLocalizedString("spam_force_banned", comment: ""),
                            Int(LocalRateLimiter.shared.forceSendBanTimeRemaining / 60)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button(LocalizedStringKey("cancel")) {
                state.showStrongSheet = false
            }
            .padding(.bottom, 24)
        }
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
