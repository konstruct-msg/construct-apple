//
//  InCallView.swift
//  Construct Messenger
//
//  Full-screen active-call overlay.
//  Japanese minimalism: one focal point (avatar), one action row.
//

import SwiftUI

#if os(iOS)
struct InCallView: View {
    let session: CallManager.CallSession
    let isConnecting: Bool
    var endReason: CallManager.EndReason? = nil

    @State private var isMuted = false
    @State private var isSpeaker = false
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    private var isEnded: Bool { endReason != nil }

    var body: some View {
        ZStack {
            Color.CT.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Avatar + name
                VStack(spacing: 16) {
                    ZStack {
                        CallAvatarView(userId: session.peerUserId, displayName: session.peerName, size: 96)
                        if isConnecting && !isEnded {
                            PulseRingView(size: 96)
                        }
                    }

                    Text(session.peerName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.CT.text)

                    Text(statusText)
                        .font(CTFont.regular(14))
                        .foregroundStyle(isEnded ? Color.red.opacity(0.85) : Color.CT.textDim)
                        .animation(.easeInOut(duration: 0.3), value: isConnecting)
                }

                Spacer()
                Spacer()

                // Control row
                if isEnded {
                    Button {
                        CallManager.shared.endCall()
                    } label: {
                        Text(NSLocalizedString("call_dismiss", comment: ""))
                            .font(CTFont.regular(15))
                            .foregroundStyle(Color.CT.textDim)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                            .background(Color.CT.bgMsg)
                            .overlay(Rectangle().strokeBorder(Color.CT.noise, lineWidth: 1))
                    }
                    .padding(.bottom, 52)
                } else {
                    HStack(spacing: 44) {
                        CallControlButton(
                            systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                            label: NSLocalizedString(isMuted ? "call_unmute" : "call_mute", comment: ""),
                            tint: isMuted ? Color.CT.accent : Color.CT.textDim
                        ) {
                            isMuted.toggle()
                            CallManager.shared.setMuted(isMuted)
                        }

                        // End call — prominent red
                        Button {
                            CallManager.shared.endCall()
                        } label: {
                            Text(CTSymbol.callEnd)
                                .font(CTFont.bold(18))
                                .foregroundStyle(.white)
                                .frame(width: 68, height: 68)
                                .background(Color.CT.danger)
                                .overlay(Rectangle().strokeBorder(Color.CT.danger, lineWidth: 1))
                        }
                        .accessibilityLabel(NSLocalizedString("call_end", comment: ""))

                        CallControlButton(
                            systemImage: isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                            label: NSLocalizedString("call_speaker", comment: ""),
                            tint: isSpeaker ? Color.CT.accent : Color.CT.textDim
                        ) {
                            isSpeaker.toggle()
                            CallManager.shared.setSpeaker(isSpeaker)
                        }
                    }
                    .padding(.bottom, 52)
                }
            }
        }
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
        if let reason = endReason {
            switch reason {
            case .hangup(let r):
                switch r {
                case .normal: return NSLocalizedString("call_ended", comment: "")
                case .declined: return NSLocalizedString("call_declined", comment: "")
                case .busy: return NSLocalizedString("call_busy", comment: "")
                case .timeout: return NSLocalizedString("call_missed", comment: "")
                default: return NSLocalizedString("call_ended", comment: "")
                }
            case .local(let msg):
                if msg.contains("TURN") { return NSLocalizedString("call_no_relay", comment: "") }
                return NSLocalizedString("call_failed", comment: "")
            case .error(_):
                return NSLocalizedString("call_failed", comment: "")
            }
        }
        if isConnecting {
            return NSLocalizedString("call_connecting", comment: "")
        }
        return formattedElapsed
    }

    // MARK: - Timer

    private var formattedElapsed: String {
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsed += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Pulse ring animation

private struct PulseRingView: View {
    let size: CGFloat
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .stroke(Color.CT.accent.opacity(opacity), lineWidth: 2)
            .scaleEffect(scale)
            .frame(width: size, height: size)
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    scale = 1.5
                    opacity = 0
                }
            }
    }
}

// MARK: - Call control button

private struct CallControlButton: View {
    let systemImage: String   // kept for accessibility, mapped to ASCII
    let label: String
    let tint: Color
    let action: () -> Void

    // Map SF Symbol names to ASCII equivalents
    private var asciiLabel: String {
        switch systemImage {
        case "mic.fill":            return "[mic]"
        case "mic.slash.fill":      return "[mute]"
        case "speaker.fill":        return "[ear]"
        case "speaker.wave.3.fill": return "[spk]"
        default:                    return "[\(systemImage)]"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(asciiLabel)
                    .font(CTFont.bold(15))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Color.CT.bgMsg)
                    .overlay(Rectangle().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                    .lineLimit(1)
                    .fixedSize()
                Text(label)
                    .font(CTFont.regular(10))
                    .foregroundStyle(Color.CT.textDim)
            }
        }
        .accessibilityLabel(label)
    }
}

#Preview {
    let session = CallManager.CallSession(
        id: UUID().uuidString,
        uuid: UUID(),
        peerUserId: "user_preview",
        peerName: "田中 あかり",
        direction: .outgoing
    )
    InCallView(session: session, isConnecting: false)
}
#endif

