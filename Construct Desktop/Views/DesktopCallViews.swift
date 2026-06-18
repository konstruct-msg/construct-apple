//
//  DesktopCallViews.swift
//  Construct Desktop
//
//  macOS call UI: compact incoming-call banner and in-call control strip.
//  No full-screen cover — macOS calls live as overlays on the main window.
//

import SwiftUI

// MARK: - Incoming Call Banner

/// Compact banner shown at the bottom-center of the window when a call arrives.
/// macOS convention: no full-screen interruption; uses close (×) affordances, not swipe.
struct DesktopIncomingCallView: View {
    let session: CallSession

    var body: some View {
        HStack(spacing: 16) {
            MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.peerName.uppercased())
                    .font(CTFont.bold(12))
                    .tracking(1)
                    .foregroundStyle(Color.CT.text)
                Text(NSLocalizedString("call_incoming_audio", comment: ""))
                    .font(CTFont.regular(11))
                    .foregroundStyle(Color.CT.textDim)
            }

            Spacer()

            // Decline
            Button {
                CallManager.shared.declineIncomingCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.CT.danger)
                    .overlay(Rectangle().strokeBorder(Color.CT.danger.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("call_decline", comment: ""))

            // Answer
            Button {
                CallManager.shared.answerIncomingCall()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.CT.accent)
                    .overlay(Rectangle().strokeBorder(Color.CT.accent.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("call_answer", comment: ""))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.CT.bgMsg)
        .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - In-Call Controls Strip

/// Compact floating strip shown while a call is active, connecting, or ended.
/// Positioned at the bottom-right of the window to stay out of the way.
struct DesktopInCallView: View {
    let session: CallSession
    let isConnecting: Bool
    var endReason: CallEndReason? = nil

    @State private var isMuted = false
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    private var isEnded: Bool { endReason != nil }

    var body: some View {
        HStack(spacing: 12) {
            MainAvatarView(userId: session.peerUserId, displayName: session.peerName, size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.peerName.uppercased())
                    .font(CTFont.bold(11))
                    .tracking(1)
                    .foregroundStyle(Color.CT.text)
                    .lineLimit(1)
                Text(statusText)
                    .font(CTFont.regular(10))
                    .foregroundStyle(isEnded ? Color.red.opacity(0.85) : Color.CT.textDim)
                    .animation(.easeInOut(duration: 0.3), value: isConnecting)
            }
            .frame(minWidth: 90)

            if isEnded {
                Button {
                    CallManager.shared.endCall()
                } label: {
                    Text(NSLocalizedString("call_dismiss", comment: ""))
                        .font(CTFont.regular(11))
                        .foregroundStyle(Color.CT.textDim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.CT.bgMsg)
                        .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else {
                // Mute
                Button {
                    isMuted.toggle()
                    CallManager.shared.setMuted(isMuted)
                } label: {
                    Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isMuted ? Color.CT.accent : Color.CT.textDim)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString(isMuted ? "call_unmute" : "call_mute", comment: ""))

                // End call
                Button {
                    CallManager.shared.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.CT.danger)
                        .overlay(Rectangle().strokeBorder(Color.CT.danger.opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("call_end", comment: ""))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.CT.bgMsg)
        .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            guard !isConnecting && !isEnded else { return }
            startTimer()
        }
        .onChange(of: isConnecting) { _, connecting in
            if !connecting && !isEnded { startTimer() } else { stopTimer() }
        }
        .onChange(of: isEnded) { _, ended in
            if ended { stopTimer() }
        }
        .onDisappear { stopTimer() }
    }

    // MARK: - Status text

    private var statusText: String {
        if isEnded {
            switch endReason {
            case .hangup(let r):
                switch r {
                case .declined:  return NSLocalizedString("call_status_declined", comment: "")
                case .busy:      return NSLocalizedString("call_status_busy", comment: "")
                default:         return elapsed > 0 ? formatDuration(elapsed) : NSLocalizedString("call_status_ended", comment: "")
                }
            case .error:   return NSLocalizedString("call_status_failed", comment: "")
            case .local:   return NSLocalizedString("call_status_ended", comment: "")
            case .none:    return NSLocalizedString("call_status_ended", comment: "")
            }
        }
        if isConnecting {
            switch session.direction {
            case .outgoing: return NSLocalizedString("call_status_calling", comment: "")
            case .incoming: return NSLocalizedString("call_status_connecting", comment: "")
            }
        }
        return elapsed > 0 ? formatDuration(elapsed) : NSLocalizedString("call_status_connected", comment: "")
    }

    private func formatDuration(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startTimer() {
        timer?.invalidate()
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in elapsed += 1 }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
