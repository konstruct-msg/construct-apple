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

    @State private var isMuted = false
    @State private var isSpeaker = false
    @State private var elapsed: Int = 0
    @State private var timer: Timer? = nil

    var body: some View {
        ZStack {
            Color.Construct.bg
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Avatar + name
                VStack(spacing: 16) {
                    HexagonAvatarView(
                        userId: session.peerUserId,
                        displayName: session.peerName,
                        size: 96
                    )
                    .overlay {
                        if isConnecting {
                            PulseRingView()
                        }
                    }

                    Text(session.peerName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.Construct.textBright)

                    Text(isConnecting ? NSLocalizedString("call_connecting", comment: "") : formattedElapsed)
                        .font(ConstructFont.mono(14))
                        .foregroundStyle(Color.Construct.textDim)
                        .animation(.easeInOut(duration: 0.3), value: isConnecting)
                }

                Spacer()
                Spacer()

                // Control row
                HStack(spacing: 44) {
                    CallControlButton(
                        systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                        label: NSLocalizedString(isMuted ? "call_unmute" : "call_mute", comment: ""),
                        tint: isMuted ? Color.Construct.accent : Color.Construct.textDim
                    ) {
                        isMuted.toggle()
                        CallManager.shared.setMuted(isMuted)
                    }

                    // End call — prominent red
                    Button {
                        CallManager.shared.endCall()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 68)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel(NSLocalizedString("call_end", comment: ""))

                    CallControlButton(
                        systemImage: isSpeaker ? "speaker.wave.3.fill" : "speaker.fill",
                        label: NSLocalizedString("call_speaker", comment: ""),
                        tint: isSpeaker ? Color.Construct.accent : Color.Construct.textDim
                    ) {
                        isSpeaker.toggle()
                        CallManager.shared.setSpeaker(isSpeaker)
                    }
                }
                .padding(.bottom, 52)
            }
        }
        .onAppear {
            guard !isConnecting else { return }
            startTimer()
        }
        .onChange(of: isConnecting) { _, connecting in
            if !connecting { startTimer() } else { stopTimer() }
        }
        .onDisappear { stopTimer() }
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
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0.5

    var body: some View {
        Circle()
            .stroke(Color.Construct.accent.opacity(opacity), lineWidth: 2)
            .scaleEffect(scale)
            .frame(width: 96, height: 96)
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
    let systemImage: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(Color.Construct.bg3)
                    .clipShape(Circle())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Color.Construct.textDim)
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
